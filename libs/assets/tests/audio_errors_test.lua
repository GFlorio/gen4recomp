-- AudioErrors owns the malformed generated-audio-asset codes: the leaf
-- validators raise exactly these shared constants, so a rename stays in one
-- place. Runtime audio errors live in the engine's audio errors module;
-- this module is the asset-side home only.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")

local T = {}

local function audioErrors()
  return require("libs.assets.src.AudioErrors")
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.audio_asset_codes_are_owned_here()
  local AudioErrors = audioErrors()
  Assert.equal(AudioErrors.AUDIO_SEQUENCE_INVALID, "AUDIO_SEQUENCE_INVALID")
  Assert.equal(AudioErrors.AUDIO_BANK_INVALID, "AUDIO_BANK_INVALID")
  Assert.equal(AudioErrors.AUDIO_SAMPLE_INVALID, "AUDIO_SAMPLE_INVALID")
end

-- The raise sites produce exactly the shared constants, never a drifting
-- literal: a malformed asset fails with the module's own code.
function T.asset_validators_raise_the_shared_codes()
  local AudioErrors = audioErrors()
  local AudioSequence = require("libs.assets.src.AudioSequence")
  local AudioBank = require("libs.assets.src.AudioBank")
  local AudioSample = require("libs.assets.src.AudioSample")
  local sequence = AudioFixture.sequence(0, "SEQ_TEST", 12, 1)
  sequence.program = nil
  throwsCode(AudioErrors.AUDIO_SEQUENCE_INVALID, function()
    AudioSequence.validate(sequence)
  end)
  local bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments = {}
  throwsCode(AudioErrors.AUDIO_BANK_INVALID, function()
    AudioBank.validate(bank)
  end)
  local metadata = AudioFixture.sampleMetadata(AudioFixture.key(1), { frames = 4 })
  metadata.schema = nil
  throwsCode(AudioErrors.AUDIO_SAMPLE_INVALID, function()
    AudioSample.validate(metadata)
  end)
end

return { tests = T }
