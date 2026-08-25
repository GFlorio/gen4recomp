-- Validator for the derived audio sample metadata: content-addressed by a
-- sha1 key over the full semantic sample identity (decoded PCM, base timer,
-- loop flag, loop window) that doubles as its path identity, carrying
-- engine-meaningful timing only -- frames, the DS base timer, the wave's
-- loop flag, and the loop-window frames -- never raw SWAV units. The source
-- sample rate never enters the derived shape (playback derives from the DS
-- sound clock and the calculated timer), and the payload path is not stored
-- (it is deterministically derived from the key), so either field is
-- malformed metadata. A one-shot wave (loopEnabled false) always carries the
-- full-range window: the flag owns the one-shot/loop distinction. The exact
-- payload size (#pcm == frames * 2 for PCM16LE) is part of the contract:
-- load/readback paths validate the metadata together with the payload bytes.

local AudioSample = {}

---@class AudioSample
---@field validate fun(metadata: table, pcm?: string): true

local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.assets.src.AudioErrors")
local Contract = require("libs.assets.src.DerivedAssetContract")

AudioSample.SCHEMA = Contract.audio.sampleSchema

local function fail(context)
  Errors.raise(AudioErrors.AUDIO_SAMPLE_INVALID, "malformed audio sample metadata", context)
end

---@param value any
---@return boolean
local function isNonNegativeInteger(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

-- `pcm` is the payload bytes when the caller can provide them (the provider
-- load path and the cache-writer readback): the exact payload size is then
-- part of the validation. Metadata-only callers skip the payload check.
function AudioSample.validate(metadata, pcm)
  if type(metadata) ~= "table" then
    fail({})
  end
  if metadata.schema ~= AudioSample.SCHEMA then
    fail({ field = "schema" })
  end
  if not Validate.isSha1Key(metadata.key) then
    fail({ field = "key" })
  end
  if metadata.file ~= nil then
    fail({ field = "file" })
  end
  if metadata.sampleRate ~= nil then
    fail({ field = "sampleRate" })
  end
  if not isNonNegativeInteger(metadata.frames) then
    fail({ field = "frames" })
  end
  -- The DS base timer is a positive u16: zero is an invalid rate and the
  -- source field is 16 bits.
  if
    type(metadata.baseTimer) ~= "number"
    or metadata.baseTimer % 1 ~= 0
    or metadata.baseTimer < 1
    or metadata.baseTimer > 0xFFFF
  then
    fail({ field = "baseTimer" })
  end
  local loop = metadata.loop ---@type table?
  if type(loop) ~= "table" then
    fail({ field = "loop" })
  end
  local loopValue = assert(loop) ---@type table
  if type(metadata.loopEnabled) ~= "boolean" then
    fail({ field = "loopEnabled" })
  end
  if not isNonNegativeInteger(loopValue.startFrame) or not isNonNegativeInteger(loopValue.endFrame) then
    fail({ field = "loop" })
  end
  if loopValue.startFrame >= loopValue.endFrame or loopValue.endFrame > metadata.frames then
    fail({ field = "loop" })
  end
  -- A one-shot wave loops nowhere: its window is the full range (the
  -- compiler's normalization), so the flag and the window cannot disagree.
  if not metadata.loopEnabled and (loopValue.startFrame ~= 0 or loopValue.endFrame ~= metadata.frames) then
    fail({ field = "loopEnabled" })
  end
  if pcm ~= nil then
    if type(pcm) ~= "string" or #pcm ~= metadata.frames * 2 then
      fail({ field = "pcm" })
    end
  end
  return true
end

return AudioSample
