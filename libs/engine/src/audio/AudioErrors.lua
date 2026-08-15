-- Runtime audio error codes for the engine audio subsystem: provider asset
-- resolution, sequence interpretation, and music-service availability. Every
-- module in the audio subsystem raises Errors with exactly these constants,
-- never bare literals. Malformed generated-audio-asset codes live in
-- libs/assets/src/AudioErrors.lua; SDAT/SSEQ/parser codes stay in romdump.
-- Pure domain module.

local AudioErrors = {}

AudioErrors.AUDIO_PROVIDER_INDEX_UNAVAILABLE = "AUDIO_PROVIDER_INDEX_UNAVAILABLE"
AudioErrors.AUDIO_PROVIDER_SEQUENCE_UNKNOWN = "AUDIO_PROVIDER_SEQUENCE_UNKNOWN"
AudioErrors.AUDIO_PROVIDER_BANK_UNKNOWN = "AUDIO_PROVIDER_BANK_UNKNOWN"
AudioErrors.AUDIO_PROVIDER_PLAYER_UNKNOWN = "AUDIO_PROVIDER_PLAYER_UNKNOWN"
AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN = "AUDIO_PROVIDER_SAMPLE_UNKNOWN"

AudioErrors.AUDIO_PLAYER_BANK_MISMATCH = "AUDIO_PLAYER_BANK_MISMATCH"
AudioErrors.AUDIO_PLAYER_UNSUPPORTED_AMOUNT = "AUDIO_PLAYER_UNSUPPORTED_AMOUNT"
AudioErrors.AUDIO_PLAYER_UNSUPPORTED_OP = "AUDIO_PLAYER_UNSUPPORTED_OP"
AudioErrors.AUDIO_PLAYER_UNBOUNDED_EXECUTION = "AUDIO_PLAYER_UNBOUNDED_EXECUTION"

AudioErrors.AUDIO_CRY_UNAVAILABLE = "AUDIO_CRY_UNAVAILABLE"
AudioErrors.AUDIO_MAP_MUSIC_UNAVAILABLE = "AUDIO_MAP_MUSIC_UNAVAILABLE"
AudioErrors.AUDIO_TEMPORARY_MUSIC_UNSUPPORTED = "AUDIO_TEMPORARY_MUSIC_UNSUPPORTED"

return AudioErrors
