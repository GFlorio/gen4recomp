-- AudioBank validator contract: a bank asset carries numeric and symbolic
-- identity, its wave-archive slot map, and a program-keyed instruments map.
-- Instrument kinds are the semantic direct/key_split/drum_set (never SBNK
-- record types), and every leaf voice has a generator kind
-- (sample/square/noise), an envelope, and a pan; sample voices add the
-- content-address key and root key.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioFixture = require("tests.support.AudioFixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(err.code ~= nil, "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.schema_constant_follows_the_contract()
  Assert.equal(AudioBank.SCHEMA, DerivedAssetContract.audio.bankSchema)
end

function T.accepts_a_well_formed_bank()
  Assert.isTrue(AudioBank.validate(AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })))
end

function T.validates_schema_identity_and_symbol()
  local bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  bank.schema = nil
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.schema = "g4-audio-bank-v9"
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.schema = AudioBank.SCHEMA
  bank.id = -1
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.id = 12
  bank.symbol = 7
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

function T.validates_the_wave_archive_slot_map()
  local bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  bank.waveArchives = { [4] = 31 }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.waveArchives = { [0] = -1 }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.waveArchives = { [0] = 1.5 }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

function T.validates_instrument_kinds()
  local bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  bank.instruments = {}
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments = { [0] = { kind = "record_type_1" } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments = { [0] = { kind = "direct" } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments = { [0.5] = { kind = "direct", voice = AudioFixture.sampleVoice(AudioFixture.key(1)) } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

function T.validates_key_split_and_drum_set_shapes()
  local bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  bank.instruments[1] = { kind = "key_split", ranges = "wide" }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[1] = { kind = "key_split", ranges = { { highKey = 59, voice = {} } } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[2] = { kind = "drum_set", lowKey = 35, highKey = 36 }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[2] = { kind = "drum_set", lowKey = 35, highKey = 36, voices = { AudioFixture.noiseVoice() } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[2] = { kind = "drum_set", lowKey = 36, highKey = 35, voices = {} }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  -- The malformed cases above mutate instruments in place; validate the valid
  -- drum set against a clean bank.
  bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  bank.instruments[2] = {
    kind = "drum_set",
    lowKey = 35,
    highKey = 36,
    voices = { AudioFixture.squareVoice(), AudioFixture.noiseVoice() },
  }
  Assert.isTrue(AudioBank.validate(bank), "a drum set covers every key in its range")
end

function T.validates_voice_generators()
  local bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  bank.instruments[0].voice = { generator = { kind = "sample" } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice = { generator = { kind = "sample", sample = "not-a-sha1" } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice = { generator = { kind = "sample", sample = AudioFixture.key(1) } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice = {
    generator = { kind = "square" },
    rootKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice = {
    generator = { kind = "square", duty = 0.5 },
    rootKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
  Assert.isTrue(AudioBank.validate(bank), "square voices need a duty")
  bank.instruments[0].voice = { generator = { kind = "noise" } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice = { generator = { kind = "other" } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

function T.every_voice_carries_envelope_and_pan()
  local bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  bank.instruments[0].voice.envelope = nil
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice.envelope = { attack = 0, decay = 0, sustain = 127 }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice.envelope = { attack = 0, decay = 0, sustain = 127, release = "later" }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice.envelope = { attack = 0, decay = 0, sustain = 127, release = 0 }
  bank.instruments[0].voice.pan = nil
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

-- The shared reference walk must distinguish "no sample references" (valid
-- bank) from "malformed shape" (nil), so readiness can never mistake a broken
-- bank for one without samples.
function T.sample_keys_are_nil_only_on_malformed_shapes()
  local bank = AudioFixture.bank(12, "BANK_TEST", { [0] = 31 })
  Assert.deepEqual(AudioBank.sampleKeys(bank), { AudioFixture.key(1), AudioFixture.key(2) })
  bank.instruments = {}
  Assert.isNil(AudioBank.sampleKeys(bank), "an empty instruments map is malformed, not sample-free")
  bank.instruments = { [0] = { kind = "key_split", ranges = {} } }
  Assert.isNil(AudioBank.sampleKeys(bank), "an empty key_split range set is malformed, not sample-free")
  bank.instruments = { [0] = { kind = "drum_set", lowKey = 35, highKey = 36, voices = {} } }
  Assert.isNil(AudioBank.sampleKeys(bank), "an empty drum_set voice list is malformed, not sample-free")
end

return { tests = T }
