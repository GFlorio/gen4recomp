-- Sequence lowering contract: the fixpoint walk over decoded SSEQ commands
-- emits a project-owned program whose branch targets are instruction indices
-- (never source offsets), whose entry is the track-0 start (the FE-header
-- open-track records included as ordinary instructions), whose operands are
-- normalized (plain integers or random/variable records, never clamped
-- placeholders), whose vocabulary is the closed semantic set (reserved SDK
-- no-ops lower declaratively to nop, the 0xD6 print_var diagnostic is
-- dropped), and whose unsupported or malformed forms fail with structured
-- errors carrying source provenance. Unreachable trailing bytes are never
-- decoded, so corrupted bytes outside the reachable program cannot fail a
-- build.

local Assert = require("tests.support.Assert")
local AudioSequence = require("libs.assets.src.AudioSequence")
local Errors = require("libs.errors.src.Errors")
local SequenceLowering = require("romdump.src.digest.audio.SequenceLowering")
local SseqFixture = require("tests.support.SseqFixture")

local IDENTITY = { sequenceId = 7, symbol = "SEQ_TEST" }

local T = {}

---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local function lowerOrFail(bytes, identity)
  local program, err = SequenceLowering.lower(bytes, identity or IDENTITY, "fixture")
  Assert.notNil(program, "expected lowering to succeed: " .. tostring(err and Errors.format(err) or "no error"))
  return assert(program)
end

local function lowerRejects(bytes, code, identity)
  local program, err = SequenceLowering.lower(bytes, identity or IDENTITY, "fixture")
  Assert.isNil(program, "expected lowering to fail with " .. code)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(asError(err).code, code)
  return assert(err)
end

function T.resolves_zero_target_from_the_sequence_data_base()
  local bytes = SseqFixture.build({
    { op = "jump", target = 0 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.entry, 1)
  Assert.equal(program.instructions[1].op, "jump")
  Assert.equal(program.instructions[1].target, 1)
end

-- A two-track sequence: the FE header's open-track record is an ordinary
-- instruction (track 0's first command), the entry points at it, and
-- jump/call/open_track targets are instruction indices into the same list.
function T.lowers_tracks_with_index_branch_targets()
  local bytes, layout = SseqFixture.build({
    { op = "fe", mask = 3 },
    { op = "open_track", track = 1, target = { cmd = 7 } },
    { op = "program", program = 4 },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "wait", duration = 12 },
    { op = "jump", target = { cmd = 4 } },
    { op = "note", key = 72, velocity = 80, duration = 8 },
    { op = "call", target = { cmd = 7 } },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.entry, 1, "entry is the header open-track record")

  local instructions = program.instructions
  Assert.equal(#instructions, 8)
  Assert.equal(instructions[1].op, "open_track")
  Assert.equal(instructions[1].track, 1)
  Assert.equal(instructions[1].target, 6, "open-track target is an instruction index")

  Assert.equal(instructions[2].op, "program")
  Assert.equal(instructions[2].program, 4)
  Assert.equal(instructions[3].op, "note")
  Assert.equal(instructions[3].key, 60)
  Assert.equal(instructions[4].op, "wait")
  Assert.equal(instructions[4].duration, 12)
  Assert.equal(instructions[5].op, "jump")
  Assert.equal(instructions[5].target, 3, "jump target is an instruction index")
  Assert.equal(instructions[6].op, "note")
  Assert.equal(instructions[6].key, 72)
  Assert.equal(instructions[7].op, "call")
  Assert.equal(instructions[7].target, 6, "call target is an instruction index")
  Assert.equal(instructions[8].op, "end")
end

-- A single-track sequence without an FE header starts at the first command.
function T.single_track_entry_is_the_first_command()
  local bytes = SseqFixture.build({
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.entry, 1)
  Assert.equal(program.initialTrackMask, 0x0001)
  Assert.equal(program.instructions[1].op, "note")
end

function T.derives_the_preparation_track_mask_from_the_header()
  local bytes = SseqFixture.build({
    { op = "fe", mask = 0x800A },
    { op = "open_track", track = 1, target = { cmd = 5 } },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "fin" },
    { op = "note", key = 72, velocity = 80, duration = 8 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.initialTrackMask, 0x800B)
end

-- The full semantic vocabulary lowers to lowercase semantic names, never raw
-- opcodes or offsets, and reserved commands lower to explicit no-ops. The
-- comparison commands (0xB8..0xBD) lower to normalized comparison records.
-- The 0xD6 print_var diagnostic is dropped entirely: it is never emitted into
-- the closed IR.
function T.lowers_the_semantic_vocabulary()
  local bytes = SseqFixture.build({
    { op = "wait", duration = 1 },
    { op = "u8", command = 0xC0, amount = 64 },
    { op = "u8", command = 0xC1, amount = 100 },
    { op = "u8", command = 0xC2, amount = 120 },
    { op = "u8", command = 0xC3, amount = 2 },
    { op = "u8", command = 0xC4, amount = 10 },
    { op = "u8", command = 0xC5, amount = 4 },
    { op = "u8", command = 0xC6, amount = 80 },
    { op = "u8", command = 0xC7, amount = 1 },
    { op = "u8", command = 0xC8, amount = 0 },
    { op = "u8", command = 0xC9, amount = 60 },
    { op = "u8", command = 0xCA, amount = 10 },
    { op = "u8", command = 0xCB, amount = 20 },
    { op = "u8", command = 0xCC, amount = 1 },
    { op = "u8", command = 0xCD, amount = 2 },
    { op = "u8", command = 0xCE, amount = 0 },
    { op = "u8", command = 0xCF, amount = 5 },
    { op = "u8", command = 0xD0, amount = 100 },
    { op = "u8", command = 0xD1, amount = 90 },
    { op = "u8", command = 0xD2, amount = 80 },
    { op = "u8", command = 0xD3, amount = 70 },
    { op = "u8", command = 0xD4, amount = 2 },
    { op = "u8", command = 0xD5, amount = 90 },
    { op = "u8", command = 0xD6, amount = 1 },
    { op = "u8", command = 0xD7, amount = 0 },
    { op = "u16", command = 0xE0, amount = 30 },
    { op = "u16", command = 0xE1, amount = 120 },
    { op = "u16", command = 0xE3, amount = 100 },
    { op = "setvar", var = 0, amount = 42 },
    { op = "cmp_eq", var = 0, amount = 42 },
    { op = "nop_op", command = 0x82 },
    { op = "nop_op", command = 0x91 },
    { op = "nop_op", command = 0xFC },
    { op = "ret" },
  })
  local program = lowerOrFail(bytes)
  local names = {}
  for index, instruction in ipairs(program.instructions) do
    names[index] = instruction.op
  end
  Assert.deepEqual(names, {
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
    "mod_depth",
    "mod_speed",
    "mod_type",
    "mod_range",
    "portamento",
    "portamento_time",
    "attack",
    "decay",
    "sustain",
    "release",
    "loop_begin",
    "expression",
    "mute",
    "mod_delay",
    "tempo",
    "sweep",
    "setvar",
    "compare",
    "nop",
    "nop",
    "loop_end",
    "return",
  })
  Assert.equal(program.instructions[28].var, 0)
  Assert.equal(program.instructions[28].amount, 42)
  -- 0xD4 loop_begin normalizes its u8 count into the count operand, never an
  -- amount field (the player's loop frame contract).
  Assert.equal(program.instructions[22].op, "loop_begin")
  Assert.equal(program.instructions[22].count, 2)
  Assert.isNil(program.instructions[22].amount)
  -- 0xD6 print_var emits no instruction at all.
  for _, instruction in ipairs(program.instructions) do
    Assert.isFalse(instruction.op == "print_var", "the diagnostic never enters the closed IR")
  end
end

-- The 0xD6 print_var command (a diagnostic with no runtime-observable game
-- behavior) is consumed by the walk but emits no instruction: the following
-- commands shift up by one index, and the emitted program stays inside the
-- closed op set.
function T.drops_print_var_instructions()
  local bytes = SseqFixture.build({
    { op = "wait", duration = 1 },
    { op = "u8", command = 0xD6, amount = 1 },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(#program.instructions, 3)
  Assert.equal(program.instructions[1].op, "wait")
  Assert.equal(program.instructions[2].op, "note")
  Assert.equal(program.instructions[2].duration, 24)
  Assert.equal(program.instructions[3].op, "end")
end

-- A dropped diagnostic at the track-0 entry never becomes an instruction:
-- like a branch target landing on one, the sequence is a build failure with
-- provenance rather than a silent fall-through.
function T.an_entry_on_a_dropped_diagnostic_is_a_build_failure()
  local bytes = SseqFixture.build({
    { op = "u8", command = 0xD6, amount = 1 },
    { op = "fin" },
  })
  local err = lowerRejects(bytes, "AUDIO_SEQUENCE_BAD_TARGET")
  Assert.equal(err.context.sequenceId, 7)
  Assert.equal(err.context.sequenceSymbol, "SEQ_TEST")
  Assert.notNil(err.context.sourceOffset)
end

-- A loop pair lowers to loop_begin/count plus a loop_end whose return index
-- is resolved dynamically by the player (the SDK's posCallStack at the
-- executed begin), so the emitted loop_end carries no static target.
function T.lowers_loop_pairs_without_static_loop_end_targets()
  local bytes, layout = SseqFixture.build({
    { op = "u8", command = 0xD4, amount = 0 },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "nop_op", command = 0xFC },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].op, "loop_begin")
  Assert.equal(program.instructions[1].count, 0)
  Assert.equal(program.instructions[3].op, "loop_end")
  Assert.isNil(program.instructions[3].target, "loop_end never carries a static branch target")
end

-- Random and variable operands normalize into the operand field itself: a
-- duration-class random becomes the note's duration record (no parallel
-- placeholder), a variable program becomes the program record, and byte-class
-- commands keep their amount records. Random operands keep the exact raw
-- signed pair ({kind="random", lo, hi}); the lowering never sorts endpoints
-- into a min/max range (TrackParseValue is source arithmetic, not
-- math.random(min,max)).
function T.normalizes_packed_operand_modes()
  local bytes, layout = SseqFixture.build({
    {
      op = "prefix",
      kind = "random",
      command = { op = "note", key = 50, velocity = 80, duration = { kind = "random", lo = 100, hi = 120 } },
    },
    { op = "prefix", kind = "variable", command = { op = "program", program = { kind = "variable", var = 3 } } },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC0, amount = { kind = "random", lo = 10, hi = 120 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", lo = -1, hi = 3 } },
    },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  local randomNote = program.instructions[1]
  Assert.equal(randomNote.op, "note")
  Assert.deepEqual(randomNote.duration, { kind = "random", lo = 100, hi = 120 })
  Assert.isNil(randomNote.amount, "the duration operand carries no parallel amount")

  local variableProgram = program.instructions[2]
  Assert.equal(variableProgram.op, "program")
  Assert.deepEqual(variableProgram.program, { kind = "variable", var = 3 })
  Assert.isNil(variableProgram.amount)

  local randomPan = program.instructions[3]
  Assert.equal(randomPan.op, "pan")
  Assert.deepEqual(randomPan.amount, { kind = "random", lo = 10, hi = 120 })

  local randomTranspose = program.instructions[4]
  Assert.equal(randomTranspose.op, "transpose")
  Assert.deepEqual(randomTranspose.amount, { kind = "random", lo = -1, hi = 3 })
end

-- The asset contract does not truncate duration source values: note/wait
-- durations beyond u16 survive verbatim (the source varlen encoding is wider
-- than 16 bits and the real archive contains such values), so the emitted
-- operands are never clamped placeholders. Only the note velocity, an index
-- into the 128-entry SDK volume table, stays clamped to its 0..127 range.
-- Program numbers have no such preservation floor here: Nitro stores program
-- in u16, so a test asserting an arbitrary >65535 program value survives
-- would pin behavior nobody wants (the runtime gate owns that boundary).
function T.large_durations_survive_while_velocity_stays_clamped()
  local bytes, layout = SseqFixture.build({
    { op = "note", key = 60, velocity = 193, duration = 300000 },
    { op = "wait", duration = 2089856 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].velocity, 127)
  Assert.equal(program.instructions[1].duration, 300000)
  Assert.equal(program.instructions[2].duration, 2089856)
end

-- Duration-class random operands keep the exact raw signed pair, including a
-- lo endpoint with the high bit set: the SDK's first u16 word is interpreted
-- signed, so a span a friendly min/max read would stretch past u16 instead
-- keeps its true signed lo value. The pair is carried verbatim for the
-- runtime's source-width arithmetic.
function T.random_duration_keeps_its_exact_signed_pair()
  -- A0 prefix + 0x80 wait + lo = 0xC0DD (49373) + hi = 0x0000 (0).
  local bytes = SseqFixture.build({
    { op = "raw", bytes = "\xA0\x80\xDD\xC0\x00\x00" },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].op, "wait")
  Assert.deepEqual(program.instructions[1].duration, { kind = "random", lo = -16163, hi = 0 })
end

function T.conditional_prefix_contains_the_complete_normalized_command()
  local bytes = SseqFixture.build({
    { op = "prefix", kind = "if", command = { op = "u8", command = 0xC1, amount = 100 } },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.deepEqual(program.instructions[1], {
    op = "if",
    condition = "compare_result",
    instruction = { op = "volume", amount = 100 },
  })
end

function T.conditional_terminators_keep_false_fallthrough()
  local conditionalOps = {
    { op = "jump", target = { cmd = 4 } },
    { op = "ret" },
    { op = "fin" },
  }
  for _, nested in ipairs(conditionalOps) do
    local commands = {
      { op = "cmp_eq", var = 0, amount = 1 },
      { op = "prefix", kind = "if", command = nested },
      { op = "note", key = 60, velocity = 96, duration = 24 },
      { op = "fin" },
    }
    if nested.op == "jump" then
      commands[4] = { op = "note", key = 72, velocity = 80, duration = 8 }
      commands[5] = { op = "fin" }
    end
    local bytes = SseqFixture.build(commands)
    local program = lowerOrFail(bytes)
    Assert.notNil(program.instructions[3], "conditional false fallthrough remains reachable")
    Assert.equal(program.instructions[3].op, "note", "false fallthrough remains reachable")
    Assert.equal(program.instructions[3].key, 60)
    if nested.op == "jump" then
      Assert.equal(program.instructions[4].op, "note", "the later target remains reachable")
      Assert.equal(program.instructions[4].key, 72)
      Assert.equal(program.instructions[2].instruction.target, 4)
    end
  end
end

function T.conditional_cross_track_open_keeps_fallthrough_and_valid_target()
  local bytes = SseqFixture.build({
    { op = "fe", mask = 3 },
    { op = "cmp_eq", var = 0, amount = 1 },
    { op = "prefix", kind = "if", command = { op = "open_track", track = 1, target = { cmd = 6 } } },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "fin" },
    { op = "note", key = 72, velocity = 80, duration = 8 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(#program.instructions, 6)
  Assert.equal(program.instructions[3].op, "note", "conditional false fallthrough remains reachable")
  Assert.equal(program.instructions[3].key, 60)
  Assert.equal(program.instructions[4].op, "end")
  Assert.equal(program.instructions[5].op, "note", "conditional true target remains reachable")
  Assert.equal(program.instructions[5].key, 72)
  Assert.equal(program.instructions[6].op, "end")
  Assert.deepEqual(program.instructions[2], {
    op = "if",
    condition = "compare_result",
    instruction = { op = "open_track", track = 1, target = 5 },
  })

  local sequence = {
    schema = AudioSequence.SCHEMA,
    id = IDENTITY.sequenceId,
    symbol = IDENTITY.symbol,
    bankId = 0,
    player = {
      id = 0,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    },
    program = program,
  }
  Assert.isTrue(AudioSequence.validate(sequence), "lowered cross-track open is a valid asset")
end

function T.self_open_does_not_decode_its_malformed_target()
  local bytes = SseqFixture.build({
    { op = "fe", mask = 1 },
    { op = "open_track", track = 0, target = { cmd = 4 } },
    { op = "fin" },
    { op = "raw", bytes = "\x60\x80" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(#program.instructions, 2)
  Assert.deepEqual(program.instructions[1], { op = "nop" })
  Assert.equal(program.instructions[2].op, "end")
end

-- RETURN with no active CALL/LOOP frame is a fallthrough in the ARM7
-- interpreter, so commands after it remain part of the source program.
function T.zero_depth_return_falls_through()
  local bytes = SseqFixture.build({
    { op = "ret" },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(#program.instructions, 3)
  Assert.equal(program.instructions[1].op, "return")
  Assert.equal(program.instructions[2].op, "note")
  Assert.equal(program.instructions[3].op, "end")
end

-- A called RETURN transfers to the saved caller continuation. Bytes after
-- the subroutine's RETURN are not a physical fallthrough path and may be
-- malformed without affecting lowering.
function T.called_return_reaches_the_saved_continuation_only()
  local bytes = SseqFixture.build({
    { op = "call", target = { cmd = 4 } },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "fin" },
    { op = "ret" },
    { op = "raw", bytes = "\x60\x80" },
  })
  local program = lowerOrFail(bytes)
  local names = {}
  for index, instruction in ipairs(program.instructions) do
    names[index] = instruction.op
  end
  Assert.deepEqual(names, { "call", "note", "end", "return" })
end

-- CALL and LOOP_BEGIN share the three-entry continuation stack. A CALL made
-- at saturation falls through without making its target reachable; placing a
-- marker after a terminating command makes an offset-only queue observably
-- over-approximate the source program.
function T.saturated_call_target_is_not_reachable()
  local bytes = SseqFixture.build({
    { op = "call", target = { cmd = 4 } },
    { op = "fin" },
    { op = "raw", bytes = "\x60\x80" },
    { op = "u8", command = 0xD4, amount = 1 },
    { op = "call", target = { cmd = 8 } },
    { op = "fin" },
    { op = "raw", bytes = "\x60\x80" },
    { op = "call", target = { cmd = 10 } },
    { op = "ret" },
    { op = "note", key = 72, velocity = 80, duration = 8 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  local callCount = 0
  for _, instruction in ipairs(program.instructions) do
    Assert.isFalse(instruction.op == "note" and instruction.key == 72)
    if instruction.op == "call" then
      callCount = callCount + 1
      Assert.notNil(instruction.target, "reachable CALLs must retain a valid target")
    end
  end
  Assert.equal(callCount, 2)
end

function T.unconditional_terminators_still_stop_linear_fallthrough()
  local bytes = SseqFixture.build({
    { op = "jump", target = { cmd = 4 } },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "fin" },
    { op = "note", key = 72, velocity = 80, duration = 8 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  for _, instruction in ipairs(program.instructions) do
    Assert.isFalse(instruction.op == "note" and instruction.key == 60)
  end
  Assert.isTrue(#program.instructions >= 2)
end

function T.comparison_commands_lower_to_semantic_operations()
  local bytes = SseqFixture.build({
    { op = "cmp_eq", var = 0, amount = 42 },
    { op = "cmp_ge", var = 3, amount = -7 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.deepEqual(program.instructions[1], { op = "compare", condition = "eq", var = 0, amount = 42 })
  Assert.deepEqual(program.instructions[2], { op = "compare", condition = "ge", var = 3, amount = -7 })
end

-- Unreachable trailing bytes are never decoded: a truncated command past the
-- last end cannot fail the build, and it never appears in the program.
function T.ignores_malformed_bytes_after_true_transfers()
  local cases = {
    {
      commands = {
        { op = "fin" },
      },
      expected = { "end" },
    },
    {
      commands = {
        { op = "jump", target = { cmd = 3 } },
        { op = "raw", bytes = "\x60\x80" },
        { op = "fin" },
      },
      expected = { "jump", "end" },
    },
    {
      commands = {
        { op = "call", target = { cmd = 4 } },
        { op = "fin" },
        { op = "raw", bytes = "\x60\x80" },
        { op = "ret" },
      },
      expected = { "call", "end", "return" },
    },
  }
  for _, case in ipairs(cases) do
    local bytes = SseqFixture.build(case.commands)
    local program = lowerOrFail(bytes .. "\x60\x80")
    local names = {}
    for index, instruction in ipairs(program.instructions) do
      names[index] = instruction.op
    end
    Assert.deepEqual(names, case.expected)
  end
end

-- A branch target at or past the end of the file is malformed data with
-- source provenance, never an index guess.
function T.rejects_off_boundary_targets()
  local bytes, layout = SseqFixture.build({
    { op = "wait", duration = 1 },
    { op = "jump", target = 0 },
    { op = "fin" },
  })
  local corrupted = SseqFixture.patchU24(bytes, layout.offsets[2] + 1, #bytes)
  local err = lowerRejects(corrupted, "AUDIO_SEQUENCE_BAD_TARGET")
  Assert.equal(err.context.sequenceId, 7)
  Assert.equal(err.context.sequenceSymbol, "SEQ_TEST")
  Assert.notNil(err.context.sourceOffset)
  Assert.notNil(err.context.target)
end

-- A reachable open_track whose destination track is not allocated by the
-- FE track mask is rejected at lowering: the retail corpus never contains
-- such a sequence, so the proven track set is checked at compile time and
-- runtime never carries allocation-failure state. The rejection also covers
-- a sequence with no FE header opening any track.
function T.rejects_reachable_open_track_outside_the_fe_mask()
  local bytes = SseqFixture.build({
    { op = "fe", mask = 1 },
    { op = "open_track", track = 2, target = { cmd = 3 } },
    { op = "fin" },
  })
  local err = lowerRejects(bytes, "AUDIO_SEQUENCE_TRACK_NOT_ALLOCATED")
  Assert.equal(err.context.sequenceId, 7)
  Assert.equal(err.context.sequenceSymbol, "SEQ_TEST")

  local bytesNoHeader = SseqFixture.build({
    { op = "open_track", track = 1, target = { cmd = 2 } },
    { op = "fin" },
  })
  lowerRejects(bytesNoHeader, "AUDIO_SEQUENCE_TRACK_NOT_ALLOCATED")
end

-- The s8 operand class: transpose (0xC3) and pitch_bend (0xC4) store their
-- byte as signed in the NitroSDK player (SND_seq.c: par._s8 into
-- track->transpose / track->pitchBend), so the emitted operand is the
-- already-semantic signed value, never a raw unsigned byte.
function T.lowers_s8_operands_as_signed()
  local bytes = SseqFixture.build({
    { op = "u8", command = 0xC3, amount = 0x00 },
    { op = "u8", command = 0xC3, amount = 0x7F },
    { op = "u8", command = 0xC3, amount = 0x80 },
    { op = "u8", command = 0xC3, amount = 0xFF },
    { op = "u8", command = 0xC4, amount = 0x00 },
    { op = "u8", command = 0xC4, amount = 0x7F },
    { op = "u8", command = 0xC4, amount = 0x80 },
    { op = "u8", command = 0xC4, amount = 0xFF },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].op, "transpose")
  Assert.equal(program.instructions[1].amount, 0)
  Assert.equal(program.instructions[2].amount, 127)
  Assert.equal(program.instructions[3].amount, -128)
  Assert.equal(program.instructions[4].amount, -1)
  Assert.equal(program.instructions[5].op, "pitch_bend")
  Assert.equal(program.instructions[5].amount, 0)
  Assert.equal(program.instructions[6].amount, 127)
  Assert.equal(program.instructions[7].amount, -128)
  Assert.equal(program.instructions[8].amount, -1)
end

-- The s16 operand class: sweep (0xE3) and the variable operations
-- (0xB0..0xB6) cast their u16 operand to s16 in the NitroSDK player
-- (SND_seq.c: (s16)TrackParseValue), so 0xFFFF is the semantic value -1,
-- never a raw 65535. The true-u16 class (tempo 0xE1, mod_delay 0xE0) stays
-- unsigned.
function T.lowers_s16_operands_as_signed()
  local bytes = SseqFixture.build({
    { op = "u16", command = 0xE3, amount = 0xFFFF },
    { op = "u16", command = 0xE3, amount = 0x8000 },
    { op = "u16", command = 0xE3, amount = 0x7FFF },
    { op = "setvar", var = 0, amount = 0xFFFF },
    { op = "addvar", var = 1, amount = 0x8000 },
    { op = "u16", command = 0xE1, amount = 0xFFFF },
    { op = "u16", command = 0xE0, amount = 0xFFFF },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].op, "sweep")
  Assert.equal(program.instructions[1].amount, -1)
  Assert.equal(program.instructions[2].amount, -32768)
  Assert.equal(program.instructions[3].amount, 32767)
  Assert.equal(program.instructions[4].op, "setvar")
  Assert.equal(program.instructions[4].amount, -1)
  Assert.equal(program.instructions[5].op, "addvar")
  Assert.equal(program.instructions[5].amount, -32768)
  Assert.equal(program.instructions[6].op, "tempo")
  Assert.equal(program.instructions[6].amount, 0xFFFF, "tempo is a true u16 operand")
  Assert.equal(program.instructions[7].op, "mod_delay")
  Assert.equal(program.instructions[7].amount, 0xFFFF, "mod_delay is a true u16 operand")
end

-- Random operands keep their exact signed pairs: negative and positive lo/hi
-- for the byte-class commands, and the full s16 span for the sweep class.
-- The exact raw pair (with final narrowing of a drawn value being runtime
-- work) is the semantic contract; lowering never sorts endpoints into an
-- effective min/max range.
function T.random_operands_keep_their_exact_signed_pairs()
  local bytes = SseqFixture.build({
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", lo = -128, hi = 127 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", lo = 1, hi = 127 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", lo = -128, hi = -1 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u16", command = 0xE3, amount = { kind = "random", lo = -32768, hi = 32767 } },
    },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.deepEqual(program.instructions[1].amount, { kind = "random", lo = -128, hi = 127 })
  Assert.deepEqual(program.instructions[2].amount, { kind = "random", lo = 1, hi = 127 })
  Assert.deepEqual(program.instructions[3].amount, { kind = "random", lo = -128, hi = -1 })
  Assert.deepEqual(program.instructions[4].amount, { kind = "random", lo = -32768, hi = 32767 })
end

-- Descending raw pairs stay exactly as the source byte stream presents them.
-- The SDK draws operands with its own formula and has no concept of a sorted
-- range, so lowering must not normalize lo > hi into min/max order: the
-- emitted record preserves the raw pair for the runtime.
function T.keeps_descending_random_pairs_unsorted()
  local bytes = SseqFixture.build({
    -- byte-class transpose: lo = 127, hi = -128 (A0 prefix + u8 command).
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", lo = 127, hi = -128 } },
    },
    -- duration-class wait: lo = 0, hi = -1 (A0 prefix + varlen command).
    {
      op = "prefix",
      kind = "random",
      command = { op = "wait", duration = { kind = "random", lo = 0, hi = -1 } },
    },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  local transpose = program.instructions[1]
  Assert.deepEqual(transpose.amount, { kind = "random", lo = 127, hi = -128 })
  Assert.isTrue(transpose.amount.lo > transpose.amount.hi, "the descending pair is not sorted")

  local wait = program.instructions[2]
  Assert.deepEqual(wait.duration, { kind = "random", lo = 0, hi = -1 })
  Assert.isTrue(wait.duration.lo > wait.duration.hi, "the descending pair is not sorted")
end

-- Lowering is deterministic: the same bytes always produce the same program.
function T.lowering_is_deterministic()
  local bytes, layout = SseqFixture.build({
    { op = "fe", mask = 3 },
    { op = "open_track", track = 1, target = { cmd = 3 } },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "jump", target = { cmd = 3 } },
    { op = "note", key = 72, velocity = 80, duration = 8 },
    { op = "fin" },
  })
  local first = lowerOrFail(bytes)
  local second = lowerOrFail(bytes)
  Assert.deepEqual(first, second)
end

return { tests = T }
