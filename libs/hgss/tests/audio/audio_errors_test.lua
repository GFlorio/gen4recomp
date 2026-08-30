-- HGSS audio errors cover provider resolution and semantic music-service
-- availability; NDS player errors remain with the lower sound runtime.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local NdsAudioErrors = require("libs.nds.src.nitro.sound.AudioErrors")
local HgssAudioErrors = require("libs.hgss.src.audio.AudioErrors")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.runtime_audio_codes_are_owned_here()
  local AudioErrors = HgssAudioErrors
  local codes = {
    "AUDIO_PROVIDER_INDEX_UNAVAILABLE",
    "AUDIO_PROVIDER_SEQUENCE_UNKNOWN",
    "AUDIO_PROVIDER_BANK_UNKNOWN",
    "AUDIO_PROVIDER_PLAYER_UNKNOWN",
    "AUDIO_PROVIDER_SAMPLE_UNKNOWN",
    "AUDIO_CRY_UNAVAILABLE",
    "AUDIO_MAP_MUSIC_UNAVAILABLE",
    "AUDIO_SAVE_INVALID",
  }
  for _, code in ipairs(codes) do
    Assert.equal(AudioErrors[code], code, code .. " is owned by the audio errors module")
  end
end

function T.nintendo_player_codes_are_owned_by_the_nds_runtime()
  Assert.equal(NdsAudioErrors.AUDIO_PLAYER_BANK_MISMATCH, "AUDIO_PLAYER_BANK_MISMATCH")
  Assert.equal(NdsAudioErrors.AUDIO_PLAYER_UNBOUNDED_EXECUTION, "AUDIO_PLAYER_UNBOUNDED_EXECUTION")
end

-- The provider raises exactly the shared constants on unknown references.
function T.provider_raises_the_shared_codes()
  local AudioErrors = HgssAudioErrors
  local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
  local provider = AudioAssetProvider.new(AudioFixture.readyCache())
  throwsCode(AudioErrors.AUDIO_PROVIDER_SEQUENCE_UNKNOWN, function()
    provider:sequence(99)
  end)
  throwsCode(AudioErrors.AUDIO_PROVIDER_BANK_UNKNOWN, function()
    provider:bank(99)
  end)
end

return { tests = T }
