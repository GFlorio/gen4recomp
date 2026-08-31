-- LoveAudioSink: the thin LÖVE output adapter. It owns queue management --
-- request PCM frames from the renderer, copy them into host SoundData
-- buffers (output sample rate, 16-bit, 2 channels), queue the buffers into
-- the host QueueableSource, keep the host source started (restarting it when
-- the host stops it), and release host resources exactly once -- and
-- understands nothing else: no notes, no sequence ids, no fades, no asset
-- parsing. The love.audio and love.sound namespaces and the render callable
-- are injected so the sink is testable without an audio device; the
-- production composition supplies `love.audio`, `love.sound` and the
-- SequencePlayer. The sink pumps at most one chunk per free host buffer per
-- update, so queueing is bounded by the host's buffer budget. Real LÖVE
-- copies the SoundData into the source at queue time, so a queued buffer can
-- be released immediately; buffers are allocated per chunk and released
-- right after queueing.

---@class LoveAudioSink
---@field private _audio table love.audio-shaped namespace
---@field private _sound table love.sound-shaped namespace
---@field private _renderer { render: fun(self: table, frames: integer): integer[] }
---@field private _sampleRate integer
---@field private _source table|nil
---@field private _pendingPcm integer[]|nil
---@field private _started boolean
---@field private _underrunCount integer
---@field private _released boolean
local LoveAudioSink = {}
LoveAudioSink.__index = LoveAudioSink

local CHANNELS = 2
local BIT_DEPTH = 16
-- Four queued buffers at the DS output rate (32768 Hz) are 62.5 ms of queued
-- PCM, below the project's 70 ms transport-latency ceiling.
local CHUNK_FRAMES = 512
local QUEUE_BUFFER_COUNT = 4

-- The render contract is int16 and exact: the returned PCM is
-- requestedFrames * 2 interleaved stereo samples, checked before any host
-- buffer is built. An out-of-range or fractional sample is a programming
-- fault that must fail loudly rather than be clamped silently by the host
-- buffer.
local function sampleValue(sample)
  assert(sample >= -32768 and sample <= 32767 and sample == math.floor(sample), "renderer must produce int16 samples")
  return sample / 32768
end

---@param opts { audio: table, sound: table, renderer: { render: fun(self: table, frames: integer): integer[] }, sampleRate: integer }
---@return LoveAudioSink
function LoveAudioSink.new(opts)
  assert(
    opts and opts.audio and opts.sound and opts.renderer and opts.sampleRate,
    "LoveAudioSink requires audio, sound, renderer and sampleRate"
  )
  return setmetatable({
    _audio = opts.audio,
    _sound = opts.sound,
    _renderer = opts.renderer,
    _sampleRate = opts.sampleRate,
    _source = nil,
    _pendingPcm = nil,
    _started = false,
    _underrunCount = 0,
    _released = false,
  }, LoveAudioSink)
end

-- Pumps PCM from the renderer into the host source: one pending or newly
-- rendered chunk per free host buffer, then restarts the source when the host
-- stopped it. Rendering creates pending PCM; queue success publishes it.
-- After release the pump is a no-op. Host failures follow one policy: a
-- failure anywhere in the pump -- the free-buffer query, a render, SoundData
-- construction, a queue, or the start step -- propagates from the update,
-- releases the in-flight SoundData the update did not hand off, and leaves
-- the sink usable. The source acquired by the failed update is released only
-- when the failure was not a queue handoff: a refused or failing queue means
-- the chunk was rejected while the source itself stayed healthy, so the next
-- update retries with the same source. Construction-time failures (the
-- free-buffer query, buffer build, or start step) release a source that this
-- update acquired, exactly once.
function LoveAudioSink:update()
  if self._released then
    return
  end
  local source = self._source
  local acquiredSource = source == nil
  if source == nil then
    source = self._audio.newQueueableSource(self._sampleRate, BIT_DEPTH, CHANNELS, QUEUE_BUFFER_COUNT)
    self._source = source
  end
  -- A narrowed alias for the closure below: the branch narrowing of `source`
  -- does not propagate into pcall's function.
  local live = source
  local chunk
  local queueStep = false
  local publishedToAcquiredSource = false
  local ok, err = pcall(function()
    local free = live:getFreeBufferCount()
    for _ = 1, free do
      if self._pendingPcm == nil then
        local pcm = self._renderer:render(CHUNK_FRAMES)
        assert(
          #pcm == CHUNK_FRAMES * CHANNELS,
          string.format(
            "renderer must return exactly %d stereo samples for %d frames",
            CHUNK_FRAMES * CHANNELS,
            CHUNK_FRAMES
          )
        )
        self._pendingPcm = pcm
      end
      -- SoundData's first argument is the per-channel FRAME count, not the
      -- total interleaved scalar count: a 512-frame stereo render is 1024
      -- scalars that build a 512-frame buffer with getSampleCount() == 512.
      local frameCount = #self._pendingPcm / CHANNELS
      chunk = self._sound.newSoundData(frameCount, self._sampleRate, BIT_DEPTH, CHANNELS)
      for i = 0, frameCount - 1 do
        for channel = 1, CHANNELS do
          chunk:setSample(i, channel, sampleValue(self._pendingPcm[i * CHANNELS + channel]))
        end
      end
      -- The real binding returns a success boolean from queue: an explicit
      -- `false` means the queue refused the chunk (full queue); anything else
      -- is a successful handoff. Assert the boolean so a refused chunk must
      -- fail the update, never be silently considered delivered.
      queueStep = true
      local queued = live:queue(chunk)
      if queued == false then
        error("the host queue refused the rendered chunk", 0)
      end
      queueStep = false
      publishedToAcquiredSource = true
      self._pendingPcm = nil
      local queuedChunk = chunk
      chunk = nil
      queuedChunk:release()
    end
    if not live:isPlaying() then
      if self._started then
        self._underrunCount = self._underrunCount + 1
      end
      live:play()
      self._started = true
    end
  end)
  if not ok then
    -- Release only an in-flight SoundData that was not handed off. A queue
    -- failure leaves the healthy source in place for the next update; any
    -- other pre-publication failure on a source this update constructed
    -- releases that source exactly once before the update propagates.
    if chunk ~= nil then
      chunk:release()
    end
    if acquiredSource and not queueStep and not publishedToAcquiredSource then
      live:release()
      self._source = nil
    end
    error(err, 0)
  end
end

---@return integer count number of unexpected stops after playback started
function LoveAudioSink:getUnderrunCount()
  return self._underrunCount
end

-- Releases the host source exactly once; later updates are no-ops.
function LoveAudioSink:release()
  self._released = true
  self._pendingPcm = nil
  if self._source ~= nil then
    self._source:release()
    self._source = nil
  end
end

return LoveAudioSink
