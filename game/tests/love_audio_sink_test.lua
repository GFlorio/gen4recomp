-- LoveAudioSink contract: the thin LÖVE output adapter. It owns queue
-- management -- request PCM frames from the renderer, build host SoundData
-- buffers (output sample rate, 16-bit, 2 channels) populated with the rendered
-- stereo PCM, queue them into the host QueueableSource, keep the host source
-- started/restarted, and release host resources exactly once -- and
-- understands nothing else: no notes, no sequence ids, no fades, no asset
-- parsing. The love.audio and love.sound namespaces are injected (no audio
-- device in CI); the renderer is injected as a callable so the sink is
-- testable without the whole playback stack. The renderer contract is exact
-- (#pcm == requestedFrames * 2) and the host-error policy is one policy: every
-- host failure propagates from the update and releases exactly what that
-- update acquired, leaving the sink usable.
--
-- SoundData's first argument is the per-channel frame count, NOT the total
-- interleaved scalar count: a render of 512 frames returns 1024 scalars and
-- must build a 512-frame SoundData (getSampleCount() == 512). The queue depth
-- is equally explicit: four 512-frame buffers at the 32768 Hz output rate is
-- 62.5 ms of queued PCM, within the 70 ms project budget, and the source is
-- constructed with that buffer count instead of LÖVE's accidental default
-- depth. A refused queue (the real binding returns false rather than throwing)
-- must fail the update -- a rendered chunk is never silently discarded. The
-- real-LÖVE smoke test verifies the constructed frame count where the API
-- permits.

local Assert = require("tests.support.Assert")
local LoveAudioSink = require("game.src.game.audio.LoveAudioSink")

local T = {}

local SAMPLE_RATE = 32768
local CHANNELS = 2
local BIT_DEPTH = 16

-- The explicit low-latency queue budget the sink must configure: four 512-frame
-- stereo chunks at 32768 Hz are 62.5 ms of queued PCM, within the project
-- budget. The chunk size is a FRAME count; the renderer returns twice that
-- many interleaved scalar values.
local CHUNK_FRAMES = 512
local QUEUE_BUFFER_COUNT = 4
local MAX_LATENCY_MS = 70

-- A SoundData-shaped recording object mirroring the LÖVE contract the sink
-- consumes: the constructor's first argument is a per-channel frame count
-- (real love.sound.newSoundData allocates frames * bytesPerSample * channels),
-- channels are 1-based, getSampleCount reports frames per channel, sample
-- values are floats in [-1, 1] (int16 divided by 32768), and release is
-- explicit. Written frames are tracked so a test can prove the sink populated
-- the whole buffer instead of leaving a silent second half.
local function newFakeSoundData(frames, sampleRate, bitDepth, channels)
  local data = {
    constructorFrames = frames,
    sampleRate = sampleRate,
    bitDepth = bitDepth,
    channels = channels,
    sampleCount = frames,
    samples = {},
    frameWrites = {},
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
  function data:isFrameFullyWritten(i)
    return i >= 0 and i < self.sampleCount and (self.frameWrites[i] or 0) >= self.channels
  end
  function data:writtenFrameCount()
    local count = 0
    for frame = 0, self.sampleCount - 1 do
      if self:isFrameFullyWritten(frame) then
        count = count + 1
      end
    end
    return count
  end
  function data:allFramesFullyWritten()
    return self:writtenFrameCount() == self.sampleCount
  end
  function data:getSample(i, channel)
    assert(i >= 0 and channel >= 1 and channel <= self.channels and i < self.sampleCount, "sample out of range")
    return self.samples[i * self.channels + (channel - 1)] or 0
  end
  function data:setSample(i, channel, sample)
    assert(i >= 0 and channel >= 1 and channel <= self.channels and i < self.sampleCount, "sample out of range")
    self.samples[i * self.channels + (channel - 1)] = sample
    self.frameWrites[i] = (self.frameWrites[i] or 0) + 1
  end
  function data:release()
    self.releaseCalls = self.releaseCalls + 1
  end
  return data
end

-- A love.audio + love.sound-shaped namespace with scriptable buffer
-- availability and injection points for source construction, SoundData
-- construction, queue failure/refusal, and play/free-query failures. The queue
-- rejects any payload that is not SoundData-shaped, exactly like the real
-- LÖVE binding. `freeBufferCount` overrides the source's advertised free
-- count; a nil value makes the source advertise its own explicit buffer
-- count, and `source.free` can still be adjusted between updates to simulate
-- the host playback head freeing buffers.
local function fakeHost(freeBufferCount)
  local host = {
    sources = {},
    soundData = {},
    free = freeBufferCount,
    failSource = false,
    failSoundData = false,
    failQueue = false,
    refuseQueue = false,
    failFreeBufferCount = false,
    failPlay = false,
  }
  function host.newSoundData(frames, sampleRate, bitDepth, channels)
    if host.failSoundData then
      host.failSoundData = false
      error("injected SoundData construction failure")
    end
    local data = newFakeSoundData(frames, sampleRate, bitDepth, channels)
    host.soundData[#host.soundData + 1] = data
    return data
  end
  function host.newQueueableSource(sampleRate, bitDepth, channels, bufferCount)
    if host.failSource then
      host.failSource = false
      error("injected source construction failure")
    end
    local source = {
      sampleRate = sampleRate,
      bitDepth = bitDepth,
      channels = channels,
      bufferCount = bufferCount,
      free = host.free ~= nil and host.free or bufferCount or 0,
      queueCalls = {},
      playCalls = 0,
      playing = false,
      releaseCalls = 0,
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
      if host.refuseQueue then
        host.refuseQueue = false
        return false
      end
      self.queueCalls[#self.queueCalls + 1] = data
      self.free = math.max(self.free - 1, 0)
    end
    function source:play()
      if host.failPlay then
        host.failPlay = false
        error("injected play failure")
      end
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
      if host.failFreeBufferCount then
        host.failFreeBufferCount = false
        error("injected free-buffer query failure")
      end
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
-- index) = `pattern(index)`, and records the first requested frame count so
-- tests can pin the sink's chunk size.
local function rendererReturning(pattern)
  local calls = 0
  local requested
  return {
    calls = function()
      return calls
    end,
    requestedFrameCount = function()
      return requested
    end,
    render = function(_, frames)
      assert(type(frames) == "number" and frames > 0, "the sink must request a positive frame count")
      calls = calls + 1
      requested = requested or frames
      local out = {}
      for index = 1, frames * CHANNELS do
        out[index] = pattern(index)
      end
      return out
    end,
  }
end

-- A renderer whose returned PCM length is offset from the exact stereo frame
-- count the sink requests (CHUNK_FRAMES * CHANNELS samples).
local function rendererWithLengthOffset(offset)
  return {
    render = function(_, frames)
      local out = {}
      for index = 1, frames * CHANNELS + offset do
        out[index] = 0
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

function T.update_builds_the_queueable_source_with_the_output_format_and_explicit_buffer_count()
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
  -- The queue depth is explicit, never LÖVE's accidental default depth.
  Assert.equal(
    source.bufferCount,
    QUEUE_BUFFER_COUNT,
    "the source must be constructed with the explicit queue-buffer count"
  )
  Assert.equal(renderer:calls(), 1, "one update must render exactly one chunk per free buffer")
  Assert.equal(source.playCalls, 1, "the sink must start the host source after queueing")
end

-- The central frame-count contract: a render of CHUNK_FRAMES frames returns
-- CHUNK_FRAMES * 2 interleaved scalars, and the SoundData is constructed with
-- the FRAME count, not the scalar count, so getSampleCount() reports the
-- frames per channel and no silent second half exists.
function T.sound_data_is_constructed_with_the_frame_count_and_every_frame_is_written()
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
  -- CHUNK_FRAMES stereo frames are 2 * CHUNK_FRAMES interleaved scalars, but
  -- the constructor argument (and getSampleCount) is the per-channel FRAME
  -- count.
  Assert.equal(
    chunk.constructorFrames,
    CHUNK_FRAMES,
    "newSoundData must receive the per-channel frame count, not the interleaved scalar count"
  )
  Assert.equal(chunk:getSampleCount(), CHUNK_FRAMES, "getSampleCount must report frames per channel")
  -- Renderer interleaving maps to frame/channel exactly: frame 0 L/R are
  -- scalar values 1/2, frame CHUNK_FRAMES-1 L/R are scalars 2F-1/2F.
  Assert.equal(chunk:getSample(0, 1), 1 / 32768)
  Assert.equal(chunk:getSample(0, 2), 2 / 32768)
  Assert.equal(chunk:getSample(CHUNK_FRAMES - 1, 1), (2 * CHUNK_FRAMES - 1) / 32768)
  Assert.equal(chunk:getSample(CHUNK_FRAMES - 1, 2), (2 * CHUNK_FRAMES) / 32768)
  -- No unwritten silent second half: every frame is populated and no frame
  -- exists beyond the requested count.
  Assert.isTrue(chunk:allFramesFullyWritten(), "no unwritten silent frames may remain in the chunk")
  Assert.equal(chunk:writtenFrameCount(), CHUNK_FRAMES)
  Assert.throws(function()
    chunk:getSample(CHUNK_FRAMES, 1)
  end, "no additional frame may exist beyond the requested frame count")
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

-- The required partial-availability scenarios in terms of the free count: a
-- brand-new source with two free buffers renders exactly two chunks, a full
-- source causes no renderer calls, and a single freed buffer yields exactly
-- one new chunk.
function T.a_brand_new_source_pumps_one_chunk_per_free_buffer()
  local host = fakeHost(2)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  Assert.equal(renderer:calls(), 2, "a source with two free buffers must queue exactly two chunks")
  Assert.equal(#source.queueCalls, 2)
  sink:update()
  Assert.equal(renderer:calls(), 2, "a full source must cause no renderer calls")
  Assert.equal(#source.queueCalls, 2)
  -- Simulate the host playback head freeing one buffer: exactly one chunk.
  source.free = 1
  sink:update()
  Assert.equal(renderer:calls(), 3, "one freed buffer must render exactly one new chunk")
  Assert.equal(#source.queueCalls, 3)
end

function T.a_stopped_host_source_is_restarted_without_rebuilding_it()
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
  Assert.equal(#host.sources, 1, "restarting a healthy existing source must not rebuild it")
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

-- The real LÖVE binding signals a full/refused queue by returning false rather
-- than throwing. The sink must assert that success boolean: a refused chunk is
-- never silently considered delivered, and the uniform failure policy releases
-- the in-flight SoundData while the update propagates.
function T.a_refused_queue_is_never_silently_delivered_and_fails_fast()
  local host = fakeHost(1)
  host.refuseQueue = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end, "a refused queue must fail the update instead of silently discarding the chunk")
  Assert.isTrue(tostring(err):find("queue", 1, true) ~= nil, "the failure must name the queue step")
  Assert.equal(#host.sources, 1, "the source must have been constructed before the queue step")
  Assert.equal(#host.sources[1].queueCalls, 0, "a refused chunk must not be recorded as delivered")
  Assert.equal(#host.soundData, 1, "the buffer must have been built before the queue step")
  Assert.equal(host.soundData[1].releaseCalls, 1, "the unqueued SoundData must not leak")
  sink:update()
  Assert.equal(#host.sources[1].queueCalls, 1, "the sink must stay usable and queue on the next update")
end

-- The render contract is int16; an out-of-range sample is a programming fault
-- that must fail loudly instead of being clamped silently by the host buffer,
-- and the failure must not leak the partially filled buffer.
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

-- The render contract is exact: the returned PCM must be requestedFrames * 2
-- interleaved samples, not merely an even length, and the fault is raised
-- before any host buffer is built or queued.
function T.the_renderer_length_contract_is_exact_stereo_frames_before_host_buffer_construction()
  for _, offset in ipairs({ -2, 2 }) do
    local host = fakeHost(1)
    local sink = sinkFor(host, rendererWithLengthOffset(offset))
    local err = Assert.throws(function()
      sink:update()
    end)
    Assert.isTrue(
      tostring(err):find(string.format("%d stereo samples", CHUNK_FRAMES * CHANNELS), 1, true) ~= nil,
      "the fault must name the exact expected sample count: " .. tostring(err)
    )
    Assert.equal(#host.soundData, 0, "the length check must run before any host buffer is built")
    Assert.equal(#host.sources[1].queueCalls, 0, "a wrong-length render must never reach the host queue")
  end
end

-- The host-error policy is one policy across the whole pump: a failure outside
-- the per-chunk transaction -- the free-buffer query on a source acquired by
-- this update -- propagates and releases exactly what the failed update
-- acquired, leaving the sink usable for the next update.
function T.a_free_buffer_query_failure_releases_the_acquired_source()
  local host = fakeHost(1)
  host.failFreeBufferCount = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected free-buffer query failure", 1, true) ~= nil,
    "the free-buffer query failure must propagate: " .. tostring(err)
  )
  Assert.equal(host.sources[1].releaseCalls, 1, "the acquired source must not leak on the failed update")
  sink:update()
  Assert.equal(#host.sources, 2, "the sink must stay usable and reacquire the source")
  Assert.equal(host.sources[2].releaseCalls, 0)
  Assert.equal(host.sources[2].playCalls, 1)
end

-- The same policy reaches the start step: a play failure on a source acquired
-- by this update propagates and releases that source, and the sink reacquires
-- on the next update.
function T.a_play_failure_releases_the_acquired_source()
  local host = fakeHost(1)
  host.failPlay = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected play failure", 1, true) ~= nil,
    "the play failure must propagate: " .. tostring(err)
  )
  Assert.equal(#host.sources[1].queueCalls, 1, "the chunk was queued before the start step")
  Assert.equal(host.sources[1].releaseCalls, 1, "the source acquired by the failed update must not leak")
  sink:update()
  Assert.equal(#host.sources, 2, "the sink must stay usable and reacquire the source")
  Assert.equal(host.sources[2].playCalls, 1)
end

-- The failure policy releases exactly what the failed update acquired: a
-- failure on a later update (the source pre-exists) must never release the
-- sink's own source, and the sink keeps pumping with the same source.
function T.a_later_failure_keeps_the_preexisting_source()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  host.failFreeBufferCount = true
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected free-buffer query failure", 1, true) ~= nil,
    "the later free-buffer query failure must propagate: " .. tostring(err)
  )
  Assert.equal(host.sources[1].releaseCalls, 0, "a pre-existing source is never released by a later failed update")
  sink:update()
  Assert.equal(#host.sources, 1, "the sink must keep the same source across the failure")
end

-- The explicit queue configuration must satisfy the project latency budget:
-- observed queue depth times observed chunk frames over the output rate stays
-- within MAX_LATENCY_MS of queued PCM.
function T.the_configured_queue_stays_within_the_latency_budget()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  local observedFrames = renderer:requestedFrameCount()
  local observedBuffers = source.bufferCount or 0
  Assert.equal(observedFrames, CHUNK_FRAMES, "each chunk must be exactly CHUNK_FRAMES frames")
  Assert.equal(observedBuffers, QUEUE_BUFFER_COUNT, "the queue depth must be exactly QUEUE_BUFFER_COUNT buffers")
  local budgetMs = observedBuffers * observedFrames / SAMPLE_RATE * 1000
  Assert.isTrue(
    budgetMs <= MAX_LATENCY_MS,
    string.format("queued PCM %.2f ms must stay within the %d ms budget", budgetMs, MAX_LATENCY_MS)
  )
end

return { tests = T }
