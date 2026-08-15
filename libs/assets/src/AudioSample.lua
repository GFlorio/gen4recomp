-- Validator for the derived audio sample metadata: content-addressed by a
-- sha1 key that doubles as its path identity, pointing at the canonical
-- PCM16LE payload path, carrying engine-meaningful timing (frames,
-- sampleRate, the wave's loop flag, and the loop-window frames) — never raw
-- SWAV units. A one-shot wave (loopEnabled false) always carries the
-- full-range window: the flag owns the one-shot/loop distinction.

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

function AudioSample.validate(metadata)
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
  return true
end

return AudioSample
