-- Malformed generated-audio-asset error codes: the leaf validators (sequence,
-- bank, sample) raise exactly these shared constants, so a rename stays in one
-- place, and the cache writer raises the readback code when the authoritative
-- readiness walk rejects a staged write. Runtime audio errors live in the
-- owning HGSS/NDS audio packages; this module is the asset-side home only.
-- Pure domain module.

local AudioErrors = {}

AudioErrors.AUDIO_SEQUENCE_INVALID = "AUDIO_SEQUENCE_INVALID"
AudioErrors.AUDIO_BANK_INVALID = "AUDIO_BANK_INVALID"
AudioErrors.AUDIO_SAMPLE_INVALID = "AUDIO_SAMPLE_INVALID"
AudioErrors.AUDIO_CACHE_READBACK_FAILED = "AUDIO_CACHE_READBACK_FAILED"

return AudioErrors
