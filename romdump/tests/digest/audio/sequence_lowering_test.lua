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
  Assert.equal(program.instructions[1].op, "note")
end

-- The full semantic vocabulary lowers to lowercase semantic names, never raw
-- opcodes or offsets, and reserved commands lower to explicit no-ops. The
-- comparison commands (0xB8..0xBD) have no runtime consumer once conditional
-- execution is gone, so they too lower to nop. The 0xD6 print_var diagnostic
-- is dropped entirely: it is never emitted into the closed IR.
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
    "nop",
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
-- commands keep their amount records. Duration-class randoms use the SDK's
-- effective span between the raw u16 pair; byte-class randoms keep the
-- encoder's signed pair.
function T.normalizes_packed_operand_modes()
  local bytes, layout = SseqFixture.build({
    {
      op = "prefix",
      kind = "random",
      command = { op = "note", key = 50, velocity = 80, duration = { kind = "random", min = 100, max = 120 } },
    },
    { op = "prefix", kind = "variable", command = { op = "program", program = { kind = "variable", var = 3 } } },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC0, amount = { kind = "random", min = 10, max = 120 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", min = -1, max = 3 } },
    },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  local randomNote = program.instructions[1]
  Assert.equal(randomNote.op, "note")
  Assert.deepEqual(randomNote.duration, { kind = "random", min = 100, max = 120 })
  Assert.isNil(randomNote.amount, "the duration operand carries no parallel amount")

  local variableProgram = program.instructions[2]
  Assert.equal(variableProgram.op, "program")
  Assert.deepEqual(variableProgram.program, { kind = "variable", var = 3 })
  Assert.isNil(variableProgram.amount)

  local randomPan = program.instructions[3]
  Assert.equal(randomPan.op, "pan")
  Assert.deepEqual(randomPan.amount, { kind = "random", min = 10, max = 120 })

  local randomTranspose = program.instructions[4]
  Assert.equal(randomTranspose.op, "transpose")
  Assert.deepEqual(randomTranspose.amount, { kind = "random", min = -1, max = 3 })
end

-- The asset contract does not truncate source values: durations and program
-- numbers beyond u16 survive verbatim (the source varlen encoding is wider
-- than 16 bits and the real archive contains such values), so the emitted
-- operands are never clamped placeholders. Only the note velocity, an index
-- into the 128-entry SDK volume table, stays clamped to its 0..127 range.
function T.preserves_out_of_range_value_fields()
  local bytes, layout = SseqFixture.build({
    { op = "note", key = 60, velocity = 193, duration = 300000 },
    { op = "wait", duration = 2089856 },
    { op = "program", program = 70000 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].velocity, 127)
  Assert.equal(program.instructions[1].duration, 300000)
  Assert.equal(program.instructions[2].duration, 2089856)
  Assert.equal(program.instructions[3].program, 70000)
end

-- Duration-class random operands keep their full effective span: a raw u16
-- pair whose span exceeds 0x7FFF is not truncated to the signed range. The
-- SDK draws the operand as u16(lo) + (s16(hi) - u16(lo)) * r/65536, so the
-- emitted min/max is the raw pair's effective range.
function T.preserves_random_operand_spans_beyond_u16()
  -- A0 prefix + 0x80 wait + lo = 0xC0DD (49373) + hi = 0x0000.
  local bytes = SseqFixture.build({
    { op = "raw", bytes = "\xA0\x80\xDD\xC0\x00\x00" },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].op, "wait")
  Assert.deepEqual(program.instructions[1].duration, { kind = "random", min = 0, max = 49373 })
end

-- A reachable 0xA2 conditional prefix is a compiler failure: the retail
-- census proves no reachable conditional command exists, so the derived IR
-- never carries a conditional field and the runtime needs no comparison
-- state. The rejection carries the sequence provenance like every other
-- lowering failure.
function T.reachable_conditional_prefix_is_a_compiler_failure()
  local bytes = SseqFixture.build({
    { op = "prefix", kind = "if", command = { op = "u8", command = 0xC1, amount = 100 } },
    { op = "fin" },
  })
  local err = lowerRejects(bytes, "AUDIO_SEQUENCE_CONDITIONAL_UNSUPPORTED")
  Assert.equal(err.context.sequenceId, 7)
  Assert.equal(err.context.sequenceSymbol, "SEQ_TEST")
  Assert.notNil(err.context.sourceOffset)
end

-- The comparison commands (0xB8..0xBD) lower to semantic nop instructions:
-- with no reachable conditional command to gate, no runtime comparison state
-- exists, and the operand bytes are consumed without emitting operand fields.
function T.comparison_commands_lower_to_nop()
  local bytes = SseqFixture.build({
    { op = "cmp_eq", var = 0, amount = 42 },
    { op = "cmp_ge", var = 3, amount = -7 },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.equal(program.instructions[1].op, "nop")
  Assert.isNil(program.instructions[1].var)
  Assert.isNil(program.instructions[1].amount)
  Assert.equal(program.instructions[2].op, "nop")
  Assert.isNil(program.instructions[2].var)
  Assert.isNil(program.instructions[2].amount)
end

-- Targets pointing before the data offset (into the SSEQ header region) are
-- ordinary targets; the walk treats header bytes as code exactly like the
-- inventory scanner, and the index mapping still holds.
function T.resolves_targets_into_the_header_region()
  local bytes = SseqFixture.build({
    { op = "wait", duration = 1 },
    { op = "jump", target = 0x0D },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  local jump
  for _, instruction in ipairs(program.instructions) do
    if instruction.op == "jump" then
      jump = instruction
    end
  end
  Assert.notNil(jump, "the jump instruction is present")
  Assert.equal(jump.target, 1, "header-region target maps to the walked instruction")
end

-- Unreachable trailing bytes are never decoded: a truncated command past the
-- last end cannot fail the build, and it never appears in the program.
function T.ignores_unreachable_trailing_bytes()
  local bytes = SseqFixture.build({
    { op = "fin" },
  })
  local corrupted = bytes .. "\x60\x80"
  local program = lowerOrFail(corrupted)
  Assert.equal(#program.instructions, 1)
  Assert.equal(program.instructions[1].op, "end")
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

-- Random operands keep their full signed effective span: negative and
-- positive bounds for the byte-class commands (the encoder's signed pair)
-- and the full s16 span for the sweep class. The span is the semantic
-- contract; final narrowing of a drawn value is runtime work.
function T.random_operands_keep_their_signed_spans()
  local bytes = SseqFixture.build({
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", min = -128, max = 127 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", min = 1, max = 127 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC3, amount = { kind = "random", min = -128, max = -1 } },
    },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u16", command = 0xE3, amount = { kind = "random", min = -32768, max = 32767 } },
    },
    { op = "fin" },
  })
  local program = lowerOrFail(bytes)
  Assert.deepEqual(program.instructions[1].amount, { kind = "random", min = -128, max = 127 })
  Assert.deepEqual(program.instructions[2].amount, { kind = "random", min = 1, max = 127 })
  Assert.deepEqual(program.instructions[3].amount, { kind = "random", min = -128, max = -1 })
  Assert.deepEqual(program.instructions[4].amount, { kind = "random", min = -32768, max = 32767 })
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
