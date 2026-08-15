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
---@field private _released boolean
local LoveAudioSink = {}
LoveAudioSink.__index = LoveAudioSink

local CHANNELS = 2
local BIT_DEPTH = 16
-- One chunk is about one field tick of real-time audio at the DS output
-- rate (32768/30 frames), so the per-update pump keeps the audio clock
-- near real time when the host advertises a small free-buffer budget.
local CHUNK_FRAMES = 1024

-- The render contract is int16; an out-of-range or fractional sample is a
-- programming fault that must fail loudly rather than be clamped silently by
-- the host buffer.
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
    _released = false,
  }, LoveAudioSink)
end

-- Pumps PCM from the renderer into the host source: one render + queue per
-- free host buffer, then restarts the source when the host stopped it.
-- After release the pump is a no-op. A failure inside the pump releases
-- everything the failed update acquired but did not hand off -- the
-- un-queued SoundData, and the source when this update constructed it --
-- and rethrows, leaving the sink usable for the next update.
function LoveAudioSink:update()
  if self._released then
    return
  end
  local source = self._source
  local acquiredSource = source == nil
  if source == nil then
    source = self._audio.newQueueableSource(self._sampleRate, BIT_DEPTH, CHANNELS)
    self._source = source
  end
  -- A narrowed alias for the closure below: the branch narrowing of `source`
  -- does not propagate into pcall's function.
  local live = source
  local free = live:getFreeBufferCount()
  for _ = 1, free do
    local chunk
    local ok, err = pcall(function()
      local pcm = self._renderer:render(CHUNK_FRAMES)
      assert(#pcm % CHANNELS == 0, "renderer must produce interleaved stereo PCM")
      chunk = self._sound.newSoundData(#pcm, self._sampleRate, BIT_DEPTH, CHANNELS)
      for i = 0, #pcm / CHANNELS - 1 do
        for channel = 1, CHANNELS do
          chunk:setSample(i, channel, sampleValue(pcm[i * CHANNELS + channel]))
        end
      end
      live:queue(chunk)
    end)
    if not ok then
      if chunk ~= nil then
        chunk:release()
      end
      if acquiredSource then
        live:release()
        self._source = nil
      end
      error(err, 0)
    end
    chunk:release()
  end
  if not live:isPlaying() then
    live:play()
  end
end

-- Releases the host source exactly once; later updates are no-ops.
function LoveAudioSink:release()
  self._released = true
  if self._source ~= nil then
    self._source:release()
    self._source = nil
  end
end

return LoveAudioSink
