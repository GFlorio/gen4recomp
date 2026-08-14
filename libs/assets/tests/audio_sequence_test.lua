-- AudioSequence validator contract: the project sequence asset carries a
-- schema, numeric and symbolic identity, a bank reference, a player block,
-- and a program whose branch targets are instruction indices, never source
-- offsets. Packed SSEQ operand encodings are normalized: amounts are plain
-- integers or {kind=random min max} / {kind=variable} records. The
-- instruction vocabulary itself is not closed here: the semantic name set is
-- frozen with the opcode inventory, so validation is structural (op must be a
-- non-empty string).

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local AudioSequence = require("libs.assets.src.AudioSequence")
local AudioFixture = require("tests.support.AudioFixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(err.code ~= nil, "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.schema_constant_follows_the_contract()
  Assert.equal(AudioSequence.SCHEMA, DerivedAssetContract.audio.sequenceSchema)
end

function T.accepts_a_well_formed_sequence()
  Assert.isTrue(AudioSequence.validate(AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)))
end

function T.accepts_a_symbol_free_sequence()
  local sequence = AudioFixture.sequence(42, nil, 12, 1)
  Assert.isTrue(AudioSequence.validate(sequence), "symbol is only present when one exists")
end

function T.accepts_an_unknown_semantic_operation()
  local sequence = AudioFixture.sequence(42, nil, 12, 1)
  sequence.program.instructions[2] = { op = "future_op", amount = 3 }
  Assert.isTrue(AudioSequence.validate(sequence), "the semantic vocabulary is not closed by this validator")
end

function T.validates_schema_and_identity()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.schema = nil
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.schema = "g4-audio-sequence-v9"
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.schema = AudioSequence.SCHEMA
  sequence.id = 3.5
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.id = -1
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.id = 37
  sequence.symbol = 7
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.validates_the_bank_reference()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.bankId = nil
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.bankId = 12.5
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.bankId = 0x10000
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.validates_the_player_block()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.player = nil
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.player = { id = 1, initialVolume = 127, channelPriority = 64, playerPriority = 64 }
  sequence.player.id = 0.5
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.player.id = 1
  sequence.player.initialVolume = 256
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.player.initialVolume = 127
  sequence.player.channelPriority = nil
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.validates_the_program_control_flow()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.program = nil
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program = { entry = 0, instructions = { { op = "rest", duration = 1 } } }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.entry = 2
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.entry = 1
  sequence.program.instructions = { { op = "jump" } }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions = { { op = "jump", target = 2 } }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions = { { op = "call", target = 0 } }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions = { { op = "call", target = 1.5 } }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions = {
    { op = "call", target = 2 },
    { op = "jump", target = 1 },
  }
  Assert.isTrue(AudioSequence.validate(sequence), "in-range control-flow targets are valid")
end

function T.validates_instruction_records()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.program.instructions = { 5 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions = { { duration = 3 } }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions = { { op = "" } }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions = {}
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.validates_normalized_amount_shapes()
  local function withAmount(amount)
    local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
    sequence.program.instructions[2] = { op = "pan", amount = amount }
    return sequence
  end
  Assert.isTrue(AudioSequence.validate(withAmount(-12)), "plain integer amounts stay plain")
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "random", min = -12, max = 12 })))
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "variable" })))
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount("wide"))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount(1.5))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", min = 1 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", min = 1.5, max = 2 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "other" }))
  end)
end

function T.validates_program_and_timing_fields()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.program.instructions[2] = { op = "program" }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2] = { op = "rest", duration = -1 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2] = { op = "note", key = 60, velocity = 96, duration = 24.5 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.provenance_is_allowed_but_never_required()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.provenance = { sourceOffset = 0x1A7, sourceOpcode = 0x94 }
  Assert.isTrue(AudioSequence.validate(sequence), "source provenance may ride along for diagnostics")
  sequence.provenance = "not a table"
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

return { tests = T }
