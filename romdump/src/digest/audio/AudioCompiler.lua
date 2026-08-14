-- Compiles the raw sound archive into the derived audio bundle
-- (marker/index/sequences/banks/samples/sampleMetadata/dependencies). The
-- digestion pipeline that produces this bundle is not implemented yet, so
-- compile returns a structured error: a cache build must fail loudly rather
-- than silently omit the audio class.

local Errors = require("libs.errors.src.Errors")

local AudioCompiler = {}

-- The compiler boundary is (bundle | nil, structured-error), like every other
-- stage: a not-yet-implemented pipeline is a per-version source-data failure.
---@param romFs table
---@return nil, Errors.Error
function AudioCompiler.compile(romFs)
  assert(romFs, "AudioCompiler.compile requires the raw dump")
  return nil,
    Errors.new(
      "AUDIO_COMPILER_NOT_IMPLEMENTED",
      "the sound archive digestion pipeline is not implemented yet",
      { path = "data/sound/gs_sound_data.sdat" }
    )
end

return AudioCompiler
