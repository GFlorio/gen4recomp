-- AudioSequence validator contract: the project sequence asset carries a
-- schema, numeric and symbolic identity, a bank reference, a player block,
-- and a program whose branch targets are instruction indices, never source
-- offsets. The instruction vocabulary is closed: every emitted op is a member
-- of the frozen semantic set (the lowering emits nothing else), each op
-- requires exactly its operand(s), and every operand is normalized to a plain
-- integer, {kind=random lo hi}, or {kind=variable var}. Random operands keep
-- the exact raw signed source pair: endpoints are never sorted, renamed
-- min/max, or clamped, so both endpoints must be integers in the signed-16
-- domain. Source value ranges survive: durations are not truncated to u16, so
-- any non-negative integer duration is valid. The validator rejects unknown
-- or deleted ops, missing or illegally shaped operands, extra keys anywhere --
-- including on the nested operand records -- variables without a valid
-- variable number (0..31: 16 player-local plus 16 global SDK variables),
-- invalid track numbers (0..15), out-of-range branch targets, note
-- key/velocity outside 0..127, conditional instructions (no reachable
-- retail command is conditional, so the field is forbidden at any value),
-- and extra instruction or nested-block fields (an instruction carries
-- only its op and its exact semantic operands; player carries only its
-- supported fields; program only entry and instructions).

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

-- The vocabulary is closed: an operation outside the frozen semantic set is
-- malformed, never forward-compatible, and operations no producer emits
-- (rest, the dropped print_var diagnostic) are rejected.
function T.rejects_unknown_and_deleted_operations()
  local sequence = AudioFixture.sequence(42, nil, 12, 1)
  sequence.program.instructions[2] = { op = "future_op", amount = 3 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2] = { op = "rest", duration = 3 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2] = { op = "print_var", amount = 1 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  -- The comparison operations are deleted with the conditional execution
  -- they served: no reachable retail command is conditional, so no runtime
  -- comparison state exists and no producer emits them.
  sequence.program.instructions[2] = { op = "cmp_eq", var = 0, amount = 42 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
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
  sequence.player = { id = 1, initialVolume = 127, playerPriority = 64, channelPriority = 64 }
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
  sequence.player.playerPriority = -1
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
  sequence.program = { entry = 0, instructions = { { op = "wait", duration = 1 } } }
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

-- Every op requires its operand(s): a missing operand is malformed even when
-- the op itself is closed.
function T.every_op_requires_its_operands()
  local function validateWith(instruction)
    local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
    sequence.program.instructions[2] = instruction
    return AudioSequence.validate(sequence)
  end
  for _, op in ipairs({
    "wait",
    "pan",
    "volume",
    "master_volume",
    "transpose",
    "pitch_bend",
    "pitch_bend_range",
    "priority",
    "note_wait",
    "tie",
    "portamento_key",
    "portamento",
    "portamento_time",
    "mod_depth",
    "mod_speed",
    "mod_type",
    "mod_range",
    "mod_delay",
    "attack",
    "decay",
    "sustain",
    "release",
    "expression",
    "sweep",
    "mute",
    "tempo",
  }) do
    throwsCode("AUDIO_SEQUENCE_INVALID", function()
      validateWith({ op = op })
    end)
  end
  for _, op in ipairs({
    "setvar",
    "addvar",
    "subvar",
    "mulvar",
    "divvar",
    "shiftvar",
    "randomvar",
  }) do
    throwsCode("AUDIO_SEQUENCE_INVALID", function()
      validateWith({ op = op })
    end)
    throwsCode("AUDIO_SEQUENCE_INVALID", function()
      validateWith({ op = op, var = 0 })
    end)
    throwsCode("AUDIO_SEQUENCE_INVALID", function()
      validateWith({ op = op, amount = 1 })
    end)
  end
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    validateWith({ op = "note" })
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    validateWith({ op = "note", key = 60, velocity = 96 })
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    validateWith({ op = "jump" })
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    validateWith({ op = "open_track", track = 1 })
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    validateWith({ op = "open_track", target = 1 })
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    validateWith({ op = "program" })
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    validateWith({ op = "loop_begin" })
  end)
  -- Operand-less ops accept no operand requirement.
  Assert.isTrue(validateWith({ op = "return" }))
  Assert.isTrue(validateWith({ op = "loop_end" }))
  Assert.isTrue(validateWith({ op = "end" }))
  Assert.isTrue(validateWith({ op = "nop" }))
  Assert.isTrue(validateWith({ op = "pan", amount = 64 }))
  Assert.isTrue(validateWith({ op = "setvar", var = 3, amount = 42 }))
  Assert.isTrue(validateWith({ op = "open_track", track = 1, target = 3 }))
  Assert.isTrue(validateWith({ op = "loop_begin", count = 2 }))
end

-- Normalized operands: a plain integer, a random {kind="random", lo, hi}
-- record with both endpoints integers in the signed-16 domain, or a variable
-- {kind="variable", var} record with a valid variable number. Random operands
-- keep the exact raw signed pair: endpoints are never sorted or renamed, so a
-- descending raw pair (lo > hi) is valid -- the retired friendliness-oriented
-- min/max names are rejected as extra keys -- and an endpoint outside the
-- signed-16 range is malformed.
function T.validates_normalized_amount_shapes()
  local function withAmount(amount)
    local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
    sequence.program.instructions[2] = { op = "pan", amount = amount }
    return sequence
  end
  Assert.isTrue(AudioSequence.validate(withAmount(-12)), "plain integer amounts stay plain")
  -- The exact signed pair, ascending and descending: a descending raw pair
  -- is valid because the contract forbids sorting endpoints.
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "random", lo = -12, hi = 12 })))
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "random", lo = -32768, hi = 32767 })))
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "random", lo = 127, hi = -128 })))
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "random", lo = 0, hi = -1 })))
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "variable", var = 0 })))
  Assert.isTrue(AudioSequence.validate(withAmount({ kind = "variable", var = 31 })))
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount("wide"))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount(1.5))
  end)
  -- The min/max shape is the sorted/reordered pair this contract retires;
  -- those names are not closed-shape keys whatever their relative order.
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", min = -12, max = 12 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", min = 12, max = -12 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random" }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = 1 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", hi = 1 }))
  end)
  -- Endpoints must be integers in the signed-16 domain.
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = 1.5, hi = 2 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = 1, hi = 2.5 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = 40000, hi = 0 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = 0, hi = 32768 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = -32769, hi = 0 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "other" }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "variable" }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "variable", var = 32 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "variable", var = -1 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "variable", var = 1.5 }))
  end)
end

-- Operand records are closed shapes too: a variable record carries only its
-- var, a random record only kind/lo/hi. Extra keys on an operand -- including
-- the retired min/max names riding alongside lo/hi -- are malformed, never
-- tolerated for forward-compatibility.
function T.rejects_extra_keys_on_operand_records()
  local function withAmount(amount)
    local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
    sequence.program.instructions[2] = { op = "pan", amount = amount }
    return sequence
  end
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "variable", var = 3, extra = 1 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = -12, hi = 12, extra = 1 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", lo = -12, hi = 12, min = -20 }))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withAmount({ kind = "random", min = -12, max = 12, lo = 0, hi = 0 }))
  end)
end

-- Duration-class operands are not truncated to u16: any non-negative integer
-- survives (the source varlen encoding is wider than 16 bits), so the schema
-- never clamps valid source values. A duration-class random still keeps its
-- exact signed pair -- the non-negative constraint applies only to the plain
-- integer form, never to the random endpoints.
function T.durations_are_not_truncated_to_u16()
  local function withDuration(duration)
    local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
    sequence.program.instructions[2] = { op = "wait", duration = duration }
    return sequence
  end
  Assert.isTrue(AudioSequence.validate(withDuration(0)))
  Assert.isTrue(AudioSequence.validate(withDuration(0xFFFF)))
  Assert.isTrue(AudioSequence.validate(withDuration(300000)))
  Assert.isTrue(AudioSequence.validate(withDuration(2089856)))
  Assert.isTrue(AudioSequence.validate(withDuration({ kind = "random", lo = -16163, hi = 0 })))
  Assert.isTrue(AudioSequence.validate(withDuration({ kind = "random", lo = 0, hi = -1 })))
  Assert.isTrue(AudioSequence.validate(withDuration({ kind = "variable", var = 3 })))
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withDuration(-1))
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(withDuration(1.5))
  end)
end

-- The open_track track number is an SDK track id: 16 tracks per player
-- (0..15). A track outside that range is malformed.
function T.validates_track_numbers()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.program.instructions[2] = { op = "open_track", track = 0, target = 1 }
  Assert.isTrue(AudioSequence.validate(sequence))
  sequence.program.instructions[2] = { op = "open_track", track = 15, target = 1 }
  Assert.isTrue(AudioSequence.validate(sequence))
  sequence.program.instructions[2] = { op = "open_track", track = 16, target = 1 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2] = { op = "open_track", track = -1, target = 1 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.validates_note_key_and_velocity()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.program.instructions[2] = { op = "note", key = 60, velocity = 96, duration = 24 }
  Assert.isTrue(AudioSequence.validate(sequence))
  sequence.program.instructions[2].key = 0x80
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2].key = -1
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2].key = 60
  sequence.program.instructions[2].velocity = 128
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2].velocity = -1
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.conditional_instruction_requires_a_complete_nested_command()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.program.instructions[2] = {
    op = "if",
    condition = "compare_result",
    instruction = { op = "pan", amount = 64 },
  }
  Assert.isTrue(AudioSequence.validate(sequence))
  sequence.program.instructions[2].instruction = { op = "pan", amount = 64, extra = true }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

-- Instruction shapes are exact: an instruction carries only its op and the
-- semantic operands its op requires. A raw opcode, a source offset, a mode
-- marker, a raw operand byte, or any other extra field is malformed asset
-- data, never tolerated, and an operand-less op accepts no operands at all.
function T.rejects_extra_instruction_fields()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  for _, field in ipairs({
    "opcode",
    "sourceOffset",
    "sourceOpcode",
    "sseqOpcode",
    "mode",
    "varlen",
    "raw",
    "operand",
    "offset",
  }) do
    sequence.program.instructions[2] = { op = "pan", amount = 64 }
    sequence.program.instructions[2][field] = "leak"
    throwsCode("AUDIO_SEQUENCE_INVALID", function()
      AudioSequence.validate(sequence)
    end)
  end
  sequence.program.instructions[2] = { op = "nop", amount = 1 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2] = { op = "note", key = 60, velocity = 96, duration = 24, amount = 7 }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

-- The nested blocks are exact too: sequence.player carries only its
-- supported fields, and sequence.program only entry and instructions.
function T.rejects_extra_nested_block_fields()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.player.maxSequences = 16
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.player.maxSequences = nil
  sequence.player.channelMask = 0xFFFF
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.player.channelMask = nil
  sequence.program.name = "main"
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.name = nil
  sequence.program.offsets = {}
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
end

function T.validates_program_and_timing_fields()
  local sequence = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1)
  sequence.program.instructions[2] = { op = "program" }
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    AudioSequence.validate(sequence)
  end)
  sequence.program.instructions[2] = { op = "wait", duration = -1 }
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
