-- LoveAudioSink: the thin LÖVE output adapter. It owns queue management --
-- request PCM frames from the engine, encode them as little-endian s16
-- interleaved stereo, hand them to the host QueueableSource, keep the host
-- source started (restarting it when the host stops it), and release host
-- resources exactly once -- and understands nothing else: no notes, no
-- sequence ids, no fades, no asset parsing. The love.audio namespace and the
-- engine render callable are injected so the sink is testable without an
-- audio device; the production composition supplies `love.audio` and the
-- GameSound render path. The sink pumps at most one chunk per free host
-- buffer per update, so queueing is bounded by the host's buffer budget.

---@class LoveAudioSink
---@field private _audio table love.audio-shaped namespace
---@field private _engine { render: fun(self: table, frames: integer): integer[] }
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

-- Encodes one integer sample as little-endian s16 (the LÖVE queue contract).
-- The engine contract is int16, so an out-of-range sample is a programming
-- fault: string.char fails loudly rather than silently corrupting the stream.
---@param sample integer
---@return string
local function encodeSample(sample)
  sample = math.floor(sample)
  if sample < 0 then
    sample = sample + 65536
  end
  return string.char(sample % 256, math.floor(sample / 256))
end

---@param opts { audio: table, engine: { render: fun(self: table, frames: integer): integer[] }, sampleRate: integer }
---@return LoveAudioSink
function LoveAudioSink.new(opts)
  assert(opts and opts.audio and opts.engine and opts.sampleRate, "LoveAudioSink requires audio, engine and sampleRate")
  return setmetatable({
    _audio = opts.audio,
    _engine = opts.engine,
    _sampleRate = opts.sampleRate,
    _source = nil,
    _released = false,
  }, LoveAudioSink)
end

-- Pumps PCM from the engine into the host source: one render + queue per
-- free host buffer, then restarts the source when the host stopped it.
-- After release the pump is a no-op.
function LoveAudioSink:update()
  if self._released then
    return
  end
  local source = self._source
  if source == nil then
    source = self._audio.newQueueableSource(self._sampleRate, BIT_DEPTH, CHANNELS)
    self._source = source
  end
  local free = source:getFreeBufferCount()
  for _ = 1, free do
    local samples = self._engine:render(CHUNK_FRAMES)
    local payload = {}
    for index = 1, #samples do
      payload[index] = encodeSample(samples[index])
    end
    source:queue(table.concat(payload))
  end
  if not source:isPlaying() then
    source:play()
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
