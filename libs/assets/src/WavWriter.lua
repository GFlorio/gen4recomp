-- Generic PCM16 WAV encoder for generated audio effects: a canonical
-- RIFF/WAVE container with one PCM fmt chunk and one data chunk. Owns only
-- the container; Nintendo SDAT/SSEQ interpretation stays in romdump. Pure
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")

local WavWriter = {}

---@param sampleRate integer
---@param channelCount integer
---@param pcm16 string
---@return string?
---@return Errors.Error?
function WavWriter.encode(sampleRate, channelCount, pcm16)
  if type(sampleRate) ~= "number" or sampleRate <= 0 or sampleRate % 1 ~= 0 then
    return nil, Errors.new("WAV_SHAPE_INVALID", "sample rate must be a positive integer", { sampleRate = sampleRate })
  end
  if channelCount ~= 1 and channelCount ~= 2 then
    return nil, Errors.new("WAV_SHAPE_INVALID", "channel count must be 1 or 2", { channelCount = channelCount })
  end
  if type(pcm16) ~= "string" or #pcm16 % 2 ~= 0 or #pcm16 == 0 then
    return nil,
      Errors.new("WAV_SHAPE_INVALID", "PCM16 data must be a non-empty even-length string", {
        size = type(pcm16) == "string" and #pcm16 or nil,
      })
  end
  local blockAlign = channelCount * 2
  local byteRate = sampleRate * blockAlign
  local dataSize = #pcm16
  local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
  end
  local function u32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local fmt = "fmt "
    .. u32(16)
    .. u16(1)
    .. u16(channelCount)
    .. u32(sampleRate)
    .. u32(byteRate)
    .. u16(blockAlign)
    .. u16(16)
  local body = "WAVE" .. fmt .. "data" .. u32(dataSize) .. pcm16
  return "RIFF" .. u32(#body) .. body
end

return WavWriter
