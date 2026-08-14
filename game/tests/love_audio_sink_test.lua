-- LoveAudioSink contract: the thin LÖVE output adapter. It owns
-- queue management -- request PCM frames from the engine, hand them to the
-- host QueueableSource, keep the host source started/restarted, and release
-- host resources -- and understands nothing else: no notes, no sequence ids,
-- no fades, no asset parsing. The love.audio namespace is injected (no audio
-- device in CI); the engine is injected as a render callable so the sink is
-- testable without the whole playback stack.

local Assert = require("tests.support.Assert")
local LoveAudioSink = require("game.src.game.audio.LoveAudioSink")

local T = {}

local SAMPLE_RATE = 48000

-- A love.audio-shaped recording namespace with scriptable buffer availability.
local function fakeAudioNamespace(freeBufferCount)
  local sources = {}
  local namespace = {
    sources = sources,
    created = {},
  }
  function namespace.newQueueableSource(sampleRate, bitDepth, channels)
    local source = {
      sampleRate = sampleRate,
      bitDepth = bitDepth,
      channels = channels,
      queueCalls = {},
      playCalls = 0,
      stopCalls = 0,
      pauseCalls = 0,
      playing = false,
      released = false,
      free = freeBufferCount,
    }
    function source:queue(data)
      self.queueCalls[#self.queueCalls + 1] = data
      self.free = math.max(self.free - 1, 0)
    end
    function source:play()
      self.playCalls = self.playCalls + 1
      self.playing = true
    end
    function source:stop()
      self.stopCalls = self.stopCalls + 1
      self.playing = false
    end
    function source:pause()
      self.pauseCalls = self.pauseCalls + 1
      self.playing = false
    end
    function source:isPlaying()
      return self.playing
    end
    function source:getFreeBufferCount()
      return self.free
    end
    function source:release()
      self.released = true
    end
    sources[#sources + 1] = source
    return source
  end
  return namespace
end

-- Decode little-endian s16 interleaved PCM back into an int16 array.
local function decode(data)
  local out = {}
  for index = 1, #data - 1, 2 do
    local lo = string.byte(data, index)
    local hi = string.byte(data, index + 1)
    local sample = hi * 256 + lo
    if sample >= 32768 then
      sample = sample - 65536
    end
    out[#out + 1] = sample
  end
  return out
end

local function engineReturning(samples)
  local calls = 0
  return {
    calls = function()
      return calls
    end,
    render = function(_, frames)
      assert(type(frames) == "number" and frames > 0, "the sink must request a positive frame count")
      calls = calls + 1
      return samples
    end,
  }
end

function T.update_requests_engine_pcm_and_queues_it_into_the_host_source()
  local namespace = fakeAudioNamespace(1)
  local engine = engineReturning({ 1000, -1000, 3000, -3000 })
  local sink = LoveAudioSink.new({
    audio = namespace,
    engine = engine,
    sampleRate = SAMPLE_RATE,
  })
  sink:update()
  local source = namespace.sources[1]
  Assert.notNil(source)
  Assert.equal(source.sampleRate, SAMPLE_RATE)
  Assert.equal(source.bitDepth, 16)
  Assert.equal(source.channels, 2)
  Assert.equal(engine:calls(), 1, "one update must request exactly one PCM chunk per free buffer")
  Assert.deepEqual(decode(source.queueCalls[1]), { 1000, -1000, 3000, -3000 })
  Assert.equal(source.playCalls, 1, "the sink must start the host source after queueing")
end

function T.update_queues_until_no_free_buffers_remain()
  local namespace = fakeAudioNamespace(3)
  local engine = engineReturning({ 1, -1 })
  local sink = LoveAudioSink.new({ audio = namespace, engine = engine, sampleRate = SAMPLE_RATE })
  sink:update()
  local source = namespace.sources[1]
  Assert.equal(engine:calls(), 3, "the sink must queue one chunk per free buffer")
  Assert.equal(#source.queueCalls, 3)
  sink:update()
  Assert.equal(engine:calls(), 3, "a full host queue must stop the pump")
  Assert.equal(#source.queueCalls, 3)
end

function T.a_stopped_host_source_is_restarted_on_the_next_update()
  local namespace = fakeAudioNamespace(1)
  local engine = engineReturning({ 1, -1 })
  local sink = LoveAudioSink.new({ audio = namespace, engine = engine, sampleRate = SAMPLE_RATE })
  sink:update()
  local source = namespace.sources[1]
  source:stop()
  sink:update()
  Assert.equal(source.playCalls, 2, "the sink must restart a host source that stopped")
end

function T.release_releases_the_host_source_exactly_once_and_stops_the_pump()
  local namespace = fakeAudioNamespace(1)
  local engine = engineReturning({ 1, -1 })
  local sink = LoveAudioSink.new({ audio = namespace, engine = engine, sampleRate = SAMPLE_RATE })
  sink:update()
  local source = namespace.sources[1]
  sink:release()
  sink:release()
  Assert.isTrue(source.released, "the host source must be released on release")
  local callsAfterRelease = engine:calls()
  sink:update()
  Assert.equal(engine:calls(), callsAfterRelease, "an update after release must not request more PCM")
end

function T.pcm_is_encoded_little_endian_s16_interleaved()
  local namespace = fakeAudioNamespace(1)
  local engine = engineReturning({ 0x7FFF, -0x8000, 0, 1 })
  local sink = LoveAudioSink.new({ audio = namespace, engine = engine, sampleRate = SAMPLE_RATE })
  sink:update()
  local payload = namespace.sources[1].queueCalls[1]
  Assert.equal(#payload, 8, "four samples must encode to eight bytes")
  Assert.deepEqual(decode(payload), { 0x7FFF, -0x8000, 0, 1 })
end

return { tests = T }
