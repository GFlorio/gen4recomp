-- Validator for the derived audio sample metadata: content-addressed by a
-- sha1 key over the full semantic sample identity (decoded PCM, base timer,
-- loop flag, loop window) that doubles as its path identity, pointing at the
-- canonical PCM16LE payload path, carrying engine-meaningful timing (frames,
-- sampleRate, the DS base timer, the wave's loop flag, and the loop-window
-- frames) — never raw SWAV units. A one-shot wave (loopEnabled false) always
-- carries the full-range window: the flag owns the one-shot/loop distinction.
-- The exact payload size (#pcm == frames * 2 for PCM16LE) is part of the
-- contract: load/readback paths validate the metadata together with the
-- payload bytes.

local AudioSample = {}

local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.AudioCache")
local Contract = require("libs.assets.src.DerivedAssetContract")

AudioSample.SCHEMA = Contract.audio.sampleSchema

local function fail(context)
  Errors.raise("AUDIO_SAMPLE_INVALID", "malformed audio sample metadata", context)
end

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
  if metadata.file ~= AudioCache.samplePath(metadata.key) then
    fail({ field = "file" })
  end
  if not isNonNegativeInteger(metadata.frames) then
    fail({ field = "frames" })
  end
  if type(metadata.sampleRate) ~= "number" or metadata.sampleRate % 1 ~= 0 or metadata.sampleRate <= 0 then
    fail({ field = "sampleRate" })
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
  local loop = metadata.loop
  if type(loop) ~= "table" then
    fail({ field = "loop" })
  end
  if type(metadata.loopEnabled) ~= "boolean" then
    fail({ field = "loopEnabled" })
  end
  if not isNonNegativeInteger(loop.startFrame) or not isNonNegativeInteger(loop.endFrame) then
    fail({ field = "loop" })
  end
  if loop.startFrame >= loop.endFrame or loop.endFrame > metadata.frames then
    fail({ field = "loop" })
  end
  -- A one-shot wave loops nowhere: its window is the full range (the
  -- compiler's normalization), so the flag and the window cannot disagree.
  if not metadata.loopEnabled and (loop.startFrame ~= 0 or loop.endFrame ~= metadata.frames) then
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
