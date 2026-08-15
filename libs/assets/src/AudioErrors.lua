-- Malformed generated-audio-asset error codes: the leaf validators (sequence,
-- bank, sample) raise exactly these shared constants, so a rename stays in one
-- place. Runtime audio errors live in libs/engine/src/audio/AudioErrors.lua;
-- this module is the asset-side home only. Pure domain module.

local AudioErrors = {}

AudioErrors.AUDIO_SEQUENCE_INVALID = "AUDIO_SEQUENCE_INVALID"
AudioErrors.AUDIO_BANK_INVALID = "AUDIO_BANK_INVALID"
AudioErrors.AUDIO_SAMPLE_INVALID = "AUDIO_SAMPLE_INVALID"

return AudioErrors
