-- AudioBank validator contract: a bank asset carries numeric and symbolic
-- identity, its wave-archive slot map, and a program-keyed instruments map.
-- Instrument kinds are the semantic direct/key_split/drum_set (never SBNK
-- record types), and every leaf voice has the common shape {generator,
-- originalKey, envelope, pan}: sample voices add the content-address key, and
-- square/noise voices carry their source original key like every other leaf.

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
  Assert.isTrue(AudioBank.validate(AudioFixture.bank(12, "BANK_TEST")))
end

function T.validates_schema_identity_and_symbol()
  local bank = AudioFixture.bank(12, "BANK_TEST")
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

function T.validates_instrument_kinds()
  local bank = AudioFixture.bank(12, "BANK_TEST")
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
  local bank = AudioFixture.bank(12, "BANK_TEST")
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
  bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments[2] = {
    kind = "drum_set",
    lowKey = 35,
    highKey = 36,
    voices = { AudioFixture.squareVoice(), AudioFixture.noiseVoice() },
  }
  Assert.isTrue(AudioBank.validate(bank), "a drum set covers every key in its range")
end

function T.validates_voice_generators()
  local bank = AudioFixture.bank(12, "BANK_TEST")
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
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[0].voice = {
    generator = { kind = "square", duty = 4 },
    originalKey = 60,
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

-- The common voice shape carries the source original key for every generator
-- kind: a missing or out-of-range originalKey is malformed for square and
-- noise voices exactly as for sample voices, and the old rootKey-only shape
-- (no originalKey) is rejected.
function T.every_generator_kind_requires_an_original_key()
  for _, voice in ipairs({
    AudioFixture.sampleVoice(AudioFixture.key(1)),
    AudioFixture.squareVoice(),
    AudioFixture.noiseVoice(),
  }) do
    local bank = AudioFixture.bank(12, "BANK_TEST")
    bank.instruments[0].voice = voice
    Assert.isTrue(AudioBank.validate(bank), "a well-formed voice with originalKey is valid")

    local without = {}
    for key, value in pairs(voice) do
      without[key] = value
    end
    without.originalKey = nil
    bank.instruments[0].voice = without
    throwsCode("AUDIO_BANK_INVALID", function()
      AudioBank.validate(bank)
    end)

    local outOfRange = {}
    for key, value in pairs(voice) do
      outOfRange[key] = value
    end
    outOfRange.originalKey = 128
    bank.instruments[0].voice = outOfRange
    throwsCode("AUDIO_BANK_INVALID", function()
      AudioBank.validate(bank)
    end)
  end
end

function T.every_voice_carries_envelope_and_pan()
  local bank = AudioFixture.bank(12, "BANK_TEST")
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

function T.accepts_a_dummy_leaf_and_selects_no_voice()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments[0].voice = { kind = "dummy" }
  Assert.isTrue(AudioBank.validate(bank))
  Assert.isNil(AudioBank.selectVoice(bank.instruments[0], 60))

  bank.instruments[0].voice = { kind = "dummy", generator = { kind = "noise" } }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

function T.preserves_the_release_sentinel_in_every_leaf_shape()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments[0].voice.envelope.release = 0xFF
  Assert.isTrue(AudioBank.validate(bank))
  bank.instruments[2].voices[1].envelope.release = 0xFF
  Assert.isTrue(AudioBank.validate(bank))
end

-- The square duty is the discrete DS PSG duty index 0..7 (GBATEK): an
-- integer, never a float fraction. Every index is valid, index 7 is the
-- hardware special all-LOW pattern (0% HIGH, not 100%), and a float or an
-- out-of-range index is malformed. (Lua numbers cannot distinguish the
-- literal 1.0 from the integer 1, so the float examples are non-integral
-- values.)
function T.square_duty_is_an_integer_index_0_to_7()
  for duty = 0, 7 do
    local bank = AudioFixture.bank(12, "BANK_TEST")
    bank.instruments[0].voice = {
      generator = { kind = "square", duty = duty },
      originalKey = 60,
      envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
      pan = 64,
    }
    Assert.isTrue(AudioBank.validate(bank), "duty index " .. duty .. " is valid")
  end
  local bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments[0].voice = {
    generator = { kind = "square", duty = 7 },
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  }
  Assert.isTrue(AudioBank.validate(bank), "duty index 7, the all-LOW pattern, is valid")
  for _, duty in ipairs({ 0.5, 0.625, 1.5, -1, 8, "wide" }) do
    local bank = AudioFixture.bank(12, "BANK_TEST")
    bank.instruments[0].voice = {
      generator = { kind = "square", duty = duty },
      originalKey = 60,
      envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
      pan = 64,
    }
    throwsCode("AUDIO_BANK_INVALID", function()
      AudioBank.validate(bank)
    end)
  end
end

-- The semantic leaf selection an instrument plays for a MIDI key: the
-- caller resolves the clamped transposed key first (NNS TrackPlayNote clamps
-- midiKey and SND_ReadInstData selects by it), and selection then runs on
-- that key -- a transposition crossing a key-split boundary selects the
-- range the transposed key lands in, and a transposition out of a drum
-- set's range is a miss, never the source key's voice.
function T.select_voice_uses_the_midi_key()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  local split = bank.instruments[1]
  Assert.equal(AudioBank.selectVoice(split, 55), split.ranges[1].voice, "source key 55 stays low")
  Assert.equal(AudioBank.selectVoice(split, 59), split.ranges[1].voice)
  Assert.equal(AudioBank.selectVoice(split, 60), split.ranges[2].voice, "transposed key 60 crosses the split")
  Assert.equal(AudioBank.selectVoice(split, 127), split.ranges[2].voice)
  Assert.isNil(AudioBank.selectVoice(split, -1), "a key below the lowest range is a miss")

  local drums = bank.instruments[2]
  Assert.equal(AudioBank.selectVoice(drums, 35), drums.voices[1])
  Assert.equal(AudioBank.selectVoice(drums, 36), drums.voices[2], "transposed key 36 selects the drum voice at 36")
  Assert.isNil(AudioBank.selectVoice(drums, 37), "a transposition out of the drum range is silent")

  local direct = bank.instruments[0]
  Assert.equal(AudioBank.selectVoice(direct, 60), direct.voice, "a direct instrument ignores the key")
end

-- The shared reference walk must distinguish "no sample references" (valid
-- bank) from "malformed shape" (nil), so readiness can never mistake a broken
-- bank for one without samples.
function T.sample_keys_are_nil_only_on_malformed_shapes()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  Assert.deepEqual(AudioBank.sampleKeys(bank), { AudioFixture.key(1), AudioFixture.key(2) })
  bank.instruments = {}
  Assert.isNil(AudioBank.sampleKeys(bank), "an empty instruments map is malformed, not sample-free")
  bank.instruments = { [0] = { kind = "key_split", ranges = {} } }
  Assert.isNil(AudioBank.sampleKeys(bank), "an empty key_split range set is malformed, not sample-free")
  bank.instruments = { [0] = { kind = "drum_set", lowKey = 35, highKey = 36, voices = {} } }
  Assert.isNil(AudioBank.sampleKeys(bank), "an empty drum_set voice list is malformed, not sample-free")
end

-- sampleKeys is a trusted reference walk, not a second validator: voice
-- field validity (envelope, pan, originalKey) is the validator's grammar,
-- and the walk never re-validates it — a voice the validator rejects still
-- contributes its keys, so the walk and the validator cannot drift apart.
function T.sample_keys_do_not_revalidate_voice_fields()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments[0].voice.envelope.attack = 0xFFFF
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  Assert.deepEqual(
    AudioBank.sampleKeys(bank),
    { AudioFixture.key(1), AudioFixture.key(2) },
    "the walk trusts the validator for voice fields"
  )
end

-- key_split ranges are an ordered, non-overlapping partition of the MIDI
-- domain: the compiler emits only monotonic ranges (the SDK's split-key walk
-- drops leaves with a smaller split key, so every surviving range starts
-- where the previous ended + 1). A reversed or descending list is malformed
-- even though each individual range is well formed.
function T.key_split_ranges_must_be_strictly_ascending()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments[1].ranges = {
    { lowKey = 60, highKey = 127, voice = AudioFixture.squareVoice() },
    { lowKey = 0, highKey = 59, voice = AudioFixture.sampleVoice(AudioFixture.key(1)) },
  }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[1].ranges = {
    { lowKey = 0, highKey = 59, voice = AudioFixture.sampleVoice(AudioFixture.key(1)) },
    { lowKey = 60, highKey = 127, voice = AudioFixture.squareVoice() },
    { lowKey = 30, highKey = 50, voice = AudioFixture.noiseVoice() },
  }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

-- Consecutive ranges must be strictly disjoint: an overlap -- even one that
-- ends exactly where the next begins -- would make the SDK leaf selection
-- ambiguous, so it is malformed asset data.
function T.key_split_ranges_must_not_overlap()
  local bank = AudioFixture.bank(12, "BANK_TEST")
  bank.instruments[1].ranges = {
    { lowKey = 0, highKey = 59, voice = AudioFixture.sampleVoice(AudioFixture.key(1)) },
    { lowKey = 50, highKey = 80, voice = AudioFixture.squareVoice() },
  }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
  bank.instruments[1].ranges = {
    { lowKey = 0, highKey = 59, voice = AudioFixture.sampleVoice(AudioFixture.key(1)) },
    { lowKey = 59, highKey = 80, voice = AudioFixture.squareVoice() },
  }
  throwsCode("AUDIO_BANK_INVALID", function()
    AudioBank.validate(bank)
  end)
end

return { tests = T }
