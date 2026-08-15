-- LoveAudioSink contract: the thin LÖVE output adapter. It owns
-- queue management -- request PCM frames from the renderer, build host
-- SoundData buffers (output sample rate, 16-bit, 2 channels) populated with
-- the rendered stereo PCM, queue them into the host QueueableSource, keep
-- the host source started/restarted, and release host resources exactly
-- once -- and understands nothing else: no notes, no sequence ids, no fades,
-- no asset parsing. The love.audio and love.sound namespaces are injected
-- (no audio device in CI); the renderer is injected as a callable so the
-- sink is testable without the whole playback stack. One smoke test runs the
-- sink against the real love.audio/love.sound namespaces, so the SoundData
-- constructor and accessor signatures cannot drift from the actual API.

local Assert = require("tests.support.Assert")
local LoveAudioSink = require("game.src.game.audio.LoveAudioSink")

local T = {}

local SAMPLE_RATE = 48000
local CHANNELS = 2
local BIT_DEPTH = 16

-- A SoundData-shaped recording object mirroring the LÖVE contract the sink
-- consumes: `samples` is the total sample count, channels are 1-based, sample
-- values are floats in [-1, 1] (int16 divided by 32768), and release is
-- explicit.
local function newFakeSoundData(samples, sampleRate, bitDepth, channels)
  local data = {
    sampleRate = sampleRate,
    bitDepth = bitDepth,
    channels = channels,
    sampleCount = samples,
    samples = {},
    releaseCalls = 0,
  }
  function data:getSampleRate()
    return self.sampleRate
  end
  function data:getBitDepth()
    return self.bitDepth
  end
  function data:getChannelCount()
    return self.channels
  end
  function data:getSampleCount()
    return self.sampleCount
  end
  function data:getSample(i, channel)
    assert(
      i >= 0 and channel >= 1 and channel <= self.channels and i * self.channels + (channel - 1) < self.sampleCount,
      "sample out of range"
    )
    return self.samples[i * self.channels + (channel - 1)] or 0
  end
  function data:setSample(i, channel, sample)
    assert(
      i >= 0 and channel >= 1 and channel <= self.channels and i * self.channels + (channel - 1) < self.sampleCount,
      "sample out of range"
    )
    self.samples[i * self.channels + (channel - 1)] = sample
  end
  function data:release()
    self.releaseCalls = self.releaseCalls + 1
  end
  return data
end

-- A love.audio + love.sound-shaped namespace with scriptable buffer
-- availability and injection points for source construction, SoundData
-- construction, and queue failures. The queue rejects any payload that is
-- not SoundData-shaped, exactly like the real LÖVE binding rejects the Lua
-- strings the old sink encoded.
local function fakeHost(freeBufferCount)
  local host = {
    sources = {},
    soundData = {},
    free = freeBufferCount,
    failSource = false,
    failSoundData = false,
    failQueue = false,
  }
  function host.newSoundData(samples, sampleRate, bitDepth, channels)
    if host.failSoundData then
      host.failSoundData = false
      error("injected SoundData construction failure")
    end
    local data = newFakeSoundData(samples, sampleRate, bitDepth, channels)
    host.soundData[#host.soundData + 1] = data
    return data
  end
  function host.newQueueableSource(sampleRate, bitDepth, channels)
    if host.failSource then
      host.failSource = false
      error("injected source construction failure")
    end
    local source = {
      sampleRate = sampleRate,
      bitDepth = bitDepth,
      channels = channels,
      queueCalls = {},
      playCalls = 0,
      playing = false,
      releaseCalls = 0,
      free = host.free,
    }
    function source:queue(data)
      assert(
        type(data) == "table"
          and type(data.getSample) == "function"
          and type(data.getSampleCount) == "function"
          and type(data.getChannelCount) == "function",
        "queued payload must be SoundData-shaped (a Lua byte string is not queueable)"
      )
      if host.failQueue then
        host.failQueue = false
        error("injected queue failure")
      end
      self.queueCalls[#self.queueCalls + 1] = data
      self.free = math.max(self.free - 1, 0)
    end
    function source:play()
      self.playCalls = self.playCalls + 1
      self.playing = true
    end
    function source:stop()
      self.playing = false
    end
    function source:isPlaying()
      return self.playing
    end
    function source:getFreeBufferCount()
      return self.free
    end
    function source:release()
      self.releaseCalls = self.releaseCalls + 1
    end
    host.sources[#host.sources + 1] = source
    return source
  end
  return host
end

-- A renderer that returns frames * 2 samples, sample `index` (1-based flat
-- index) from `pattern(index)`.
local function rendererReturning(pattern)
  local calls = 0
  return {
    calls = function()
      return calls
    end,
    render = function(_, frames)
      assert(type(frames) == "number" and frames > 0, "the sink must request a positive frame count")
      calls = calls + 1
      local out = {}
      for index = 1, frames * CHANNELS do
        out[index] = pattern(index)
      end
      return out
    end,
  }
end

local function sinkFor(host, renderer)
  return LoveAudioSink.new({
    audio = host,
    sound = host,
    renderer = renderer,
    sampleRate = SAMPLE_RATE,
  })
end

function T.update_builds_the_queueable_source_with_the_output_format()
  local host = fakeHost(1)
  local renderer = rendererReturning(function()
    return 0
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  Assert.notNil(source, "one update must construct the queueable source")
  Assert.equal(source.sampleRate, SAMPLE_RATE)
  Assert.equal(source.bitDepth, BIT_DEPTH)
  Assert.equal(source.channels, CHANNELS)
  Assert.equal(renderer:calls(), 1, "one update must render exactly one chunk per free buffer")
  Assert.equal(source.playCalls, 1, "the sink must start the host source after queueing")
end

function T.queued_chunks_are_sound_data_of_the_output_format_with_the_rendered_pcm()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local chunk = host.sources[1].queueCalls[1]
  -- Every queued object is SoundData-shaped, never a Lua byte string.
  Assert.equal(type(chunk.getSample), "function")
  Assert.equal(type(chunk.setSample), "function")
  Assert.equal(type(chunk.getSampleCount), "function")
  Assert.equal(type(chunk.release), "function")
  -- The buffer matches the required sample format.
  Assert.equal(chunk:getSampleRate(), SAMPLE_RATE)
  Assert.equal(chunk:getBitDepth(), BIT_DEPTH)
  Assert.equal(chunk:getChannelCount(), CHANNELS)
  -- 1024 frames of stereo PCM => 2048 total samples, populated as int16/32768
  -- floats with the renderer's left/right interleaving.
  Assert.equal(chunk:getSampleCount(), 2048)
  Assert.equal(chunk:getSample(0, 1), 1 / 32768)
  Assert.equal(chunk:getSample(0, 2), 2 / 32768)
  Assert.equal(chunk:getSample(1023, 1), 2047 / 32768)
  Assert.equal(chunk:getSample(1023, 2), 2048 / 32768)
end

function T.free_buffer_count_controls_how_many_chunks_are_queued()
  local host = fakeHost(3)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  Assert.equal(renderer:calls(), 3, "the sink must queue one chunk per free buffer")
  Assert.equal(#source.queueCalls, 3)
  for index = 1, 3 do
    Assert.equal(
      host.soundData[index].releaseCalls,
      1,
      "the host copies the SoundData at queue time, so a queued buffer is released right after queueing"
    )
  end
  sink:update()
  Assert.equal(renderer:calls(), 3, "a full host queue must stop the pump")
  Assert.equal(#source.queueCalls, 3)
end

function T.a_stopped_host_source_is_restarted_on_the_next_update()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  source:stop()
  sink:update()
  Assert.equal(source.playCalls, 2, "the sink must restart a host source that stopped")
end

function T.release_releases_the_host_source_exactly_once_and_stops_the_pump()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  sink:release()
  sink:release()
  Assert.equal(source.releaseCalls, 1, "the host source must be released exactly once")
  local callsAfterRelease = renderer:calls()
  sink:update()
  Assert.equal(renderer:calls(), callsAfterRelease, "an update after release must not request more PCM")
  Assert.equal(#host.sources, 1, "an update after release must not reacquire a source")
end

function T.a_sound_data_construction_failure_releases_the_partially_acquired_source()
  local host = fakeHost(1)
  host.failSoundData = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected SoundData construction failure", 1, true) ~= nil,
    "the construction failure must propagate: " .. tostring(err)
  )
  Assert.equal(#host.sources, 1, "the source must have been constructed before the buffer step")
  Assert.equal(host.sources[1].releaseCalls, 1, "the partially acquired source must not leak")
  sink:update()
  Assert.equal(#host.sources, 2, "the sink must stay usable and reacquire the source after the failure")
  Assert.equal(host.sources[2].releaseCalls, 0)
  Assert.equal(host.sources[2].playCalls, 1)
end

function T.a_queue_failure_releases_the_unqueued_sound_data()
  local host = fakeHost(1)
  host.failQueue = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected queue failure", 1, true) ~= nil,
    "the queue failure must propagate: " .. tostring(err)
  )
  Assert.equal(#host.soundData, 1, "the buffer must have been built before the queue step")
  Assert.equal(host.soundData[1].releaseCalls, 1, "the unqueued SoundData must not leak")
end

-- The render contract is int16; an out-of-range sample is a programming
-- fault that must fail loudly instead of being clamped silently by the host
-- buffer, and the failure must not leak the partially filled buffer.
function T.an_out_of_range_renderer_sample_fails_loudly_without_leaking_the_chunk()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index == 1 and 40000 or 0
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("int16", 1, true) ~= nil,
    "the fault must name the int16 render contract: " .. tostring(err)
  )
  Assert.equal(#host.soundData, 1, "the buffer must have been built before the range check")
  Assert.equal(host.soundData[1].releaseCalls, 1, "the unqueued SoundData must not leak")
  Assert.equal(#host.sources, 1, "the source must have been constructed before the buffer step")
  Assert.equal(host.sources[1].releaseCalls, 1, "the partially acquired source must not leak")
end

-- The signature drift guard: real love.sound.newSoundData (samples, rate,
-- depth, channels), the 1-based channel accessor, and real
-- love.audio.newQueueableSource/queue/play all work headless, so the smoke
-- test runs the sink against the actual host API. A wrong constructor or
-- accessor signature raises against the real binding.
function T.real_love_sound_and_audio_namespaces_accept_the_sinks_queueing(context)
  if not (love and love.audio and love.sound and love.audio.newQueueableSource and love.sound.newSoundData) then
    context:skip("host has no sound module (love.sound/love.audio)")
  end
  local probe = love.audio.newQueueableSource(SAMPLE_RATE, BIT_DEPTH, CHANNELS)
  local free = probe:getFreeBufferCount()
  probe:release()
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = LoveAudioSink.new({
    audio = love.audio,
    sound = love.sound,
    renderer = renderer,
    sampleRate = SAMPLE_RATE,
  })
  sink:update()
  Assert.equal(renderer:calls(), free, "the sink must pump one chunk per real free buffer")
  Assert.equal(love.audio.getActiveSourceCount(), 1, "the queued real source must be playing")
  sink:release()
  local callsAfterRelease = renderer:calls()
  sink:update()
  Assert.equal(renderer:calls(), callsAfterRelease, "an update after release must not pump")
end

return { tests = T }
