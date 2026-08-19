-- SSEQ command decoding contract: bounded, bounds-checked decoding of the
-- NNS sequence command stream (data offset header, prefix bytes, packed
-- operands) into normalized command records. Layout and operand encodings
-- follow the ARM7 NitroSDK sequence player (SND_seq.c: TrackStepTicks and
-- TrackParseValue) as mirrored in the HGSS dump: notes carry a velocity byte
-- and a variable-length duration, 0x80-0x8F a variable-length value,
-- 0x90-0x9F branches and reserved forms, 0xA0/0xA1/0xA2 prefixes, 0xB0-0xBF a
-- var number plus u16, 0xC0-0xDF a u8, 0xE0-0xEF a u16, 0xF0-0xFF nothing.
-- Random operands (u16 lo, u16 hi) normalize to {kind="random", lo, hi}
-- records keeping the raw SDK pair; variable operands to
-- {kind="variable", var}. Every malformed read fails with a structured
-- SSEQ_* error, never with slicing behavior.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Sseq = require("romdump.src.digest.audio.Sseq")
local SseqFixture = require("tests.support.SseqFixture")

local T = {}

---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local function openOrFail(bytes)
  local seq, err = Sseq.open(bytes, "fixture")
  Assert.notNil(seq, "expected open to succeed: " .. tostring(err))
  return assert(seq)
end

local function commandAt(bytes, offset, endPos)
  local cmd, err = Sseq.decodeCommand(bytes, offset, endPos or #bytes, "fixture")
  Assert.notNil(cmd, "expected decode to succeed: " .. tostring(err))
  return assert(cmd)
end

local function rejects(bytes, code)
  local cmd, err = Sseq.decodeCommand(bytes, 0x1C, #bytes, "fixture")
  Assert.isNil(cmd, "expected decode to fail with " .. code)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(asError(err).code, code)
end

-- The four core commands decode with their normalized operands.
function T.decodes_notes_waits_programs_and_branches()
  local bytes, layout = SseqFixture.build({
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "wait", duration = 12 },
    { op = "program", program = 4 },
    { op = "jump", target = { cmd = 1 } },
    { op = "call", target = { cmd = 1 } },
    { op = "open_track", track = 1, target = { cmd = 1 } },
    { op = "ret" },
    { op = "fin" },
  })
  openOrFail(bytes)

  local note = commandAt(bytes, layout.offsets[1])
  Assert.equal(note.opcode, 60)
  Assert.equal(note.mode, "plain")
  Assert.equal(note.velocity, 96)
  Assert.equal(note.duration, 24)
  Assert.equal(note.next, layout.offsets[2])

  local wait = commandAt(bytes, layout.offsets[2])
  Assert.equal(wait.opcode, 0x80)
  Assert.equal(wait.value, 12)

  local program = commandAt(bytes, layout.offsets[3])
  Assert.equal(program.opcode, 0x81)
  Assert.equal(program.value, 4)

  local jump = commandAt(bytes, layout.offsets[4])
  Assert.equal(jump.opcode, 0x94)
  Assert.equal(jump.target, layout.offsets[1])

  local call = commandAt(bytes, layout.offsets[5])
  Assert.equal(call.opcode, 0x95)
  Assert.equal(call.target, layout.offsets[1])

  local openTrack = commandAt(bytes, layout.offsets[6])
  Assert.equal(openTrack.opcode, 0x93)
  Assert.equal(openTrack.track, 1)
  Assert.equal(openTrack.target, layout.offsets[1])

  Assert.equal(commandAt(bytes, layout.offsets[7]).opcode, 0xFD)
  Assert.equal(commandAt(bytes, layout.offsets[8]).opcode, 0xFF)
end

-- Variable-length operands span multiple bytes (0x82 0x2C = 300).
function T.decodes_multibyte_varlen_operands()
  local bytes, layout = SseqFixture.build({
    { op = "note", key = 40, velocity = 64, duration = 300 },
    { op = "wait", duration = 16384 },
    { op = "fin" },
  })
  local note = commandAt(bytes, layout.offsets[1])
  Assert.equal(note.duration, 300)
  Assert.equal(note.next, layout.offsets[2])
  Assert.equal(commandAt(bytes, layout.offsets[2]).value, 16384)
end

-- The A0/A1 prefixes normalize random and variable operands into records.
-- Random records keep the raw SDK pair (first u16, second u16 signed).
function T.random_and_variable_prefixes_normalize_operands()
  local bytes, layout = SseqFixture.build({
    {
      op = "prefix",
      kind = "random",
      command = { op = "note", key = 50, velocity = 80, duration = { kind = "random", lo = -12, hi = 12 } },
    },
    { op = "prefix", kind = "variable", command = { op = "program", program = { kind = "variable", var = 3 } } },
    {
      op = "prefix",
      kind = "random",
      command = { op = "u8", command = 0xC0, amount = { kind = "random", lo = 0, hi = 127 } },
    },
    { op = "fin" },
  })
  local randomNote = commandAt(bytes, layout.offsets[1])
  Assert.equal(randomNote.mode, "random")
  Assert.equal(randomNote.velocity, 80)
  Assert.deepEqual(randomNote.duration, { kind = "random", lo = 65524, hi = 12 })
  Assert.equal(randomNote.next, layout.offsets[2])

  local variableProgram = commandAt(bytes, layout.offsets[2])
  Assert.equal(variableProgram.mode, "variable")
  Assert.deepEqual(variableProgram.value, { kind = "variable", var = 3 })

  local randomPan = commandAt(bytes, layout.offsets[3])
  Assert.equal(randomPan.opcode, 0xC0)
  Assert.equal(randomPan.mode, "random")
  Assert.deepEqual(randomPan.value, { kind = "random", lo = 0, hi = 127 })
end

-- The A2 prefix marks a command as conditional without changing its operands.
function T.conditional_prefix_marks_the_command()
  local bytes, layout = SseqFixture.build({
    { op = "prefix", kind = "if", command = { op = "u8", command = 0xC1, amount = 100 } },
    { op = "fin" },
  })
  local cmd = commandAt(bytes, layout.offsets[1])
  Assert.equal(cmd.opcode, 0xC1)
  Assert.equal(cmd.mode, "plain")
  Assert.isTrue(cmd.conditional)
  Assert.equal(cmd.value, 100)
end

-- The variable family carries its variable number and a u16 (or normalized)
-- value; comparisons are ordinary commands of the same family.
function T.setvar_family_carries_var_and_amount()
  local bytes, layout = SseqFixture.build({
    { op = "setvar", var = 0, amount = 42 },
    {
      op = "prefix",
      kind = "random",
      command = { op = "addvar", var = 1, amount = { kind = "random", lo = -5, hi = 5 } },
    },
    { op = "cmp_ne", var = 2, amount = 3 },
    { op = "fin" },
  })
  local setvar = commandAt(bytes, layout.offsets[1])
  Assert.equal(setvar.opcode, 0xB0)
  Assert.equal(setvar.var, 0)
  Assert.equal(setvar.value, 42)

  local addvar = commandAt(bytes, layout.offsets[2])
  Assert.equal(addvar.opcode, 0xB1)
  Assert.equal(addvar.mode, "random")
  Assert.equal(addvar.var, 1)
  Assert.deepEqual(addvar.value, { kind = "random", lo = 65531, hi = 5 })

  local cmp = commandAt(bytes, layout.offsets[3])
  Assert.equal(cmp.opcode, 0xBD)
  Assert.equal(cmp.var, 2)
  Assert.equal(cmp.value, 3)
end

-- Reserved commands of every operand class decode without operands.
function T.reserved_commands_decode_without_operands()
  local bytes, layout = SseqFixture.build({
    { op = "nop_op", command = 0x91 },
    { op = "nop_op", command = 0x96 },
    { op = "nop_op", command = 0xA7 },
    { op = "nop_op", command = 0xAB },
    { op = "nop_op", command = 0xF2 },
    { op = "nop_op", command = 0xFE },
    { op = "fin" },
  })
  for index = 1, 6 do
    local cmd = commandAt(bytes, layout.offsets[index])
    Assert.equal(cmd.value, nil, "reserved command " .. index .. " has no operand")
    Assert.equal(cmd.target, nil, "reserved command " .. index .. " has no target")
    Assert.equal(cmd.next, layout.offsets[index + 1], "reserved command " .. index .. " length")
  end
end

-- The data offset must point inside the file.
function T.rejects_data_offset_out_of_bounds()
  local bytes = SseqFixture.build({ { op = "fin" } })
  local corrupted = bytes:sub(1, 0x18) .. "\x00\x00\x00\x00" .. bytes:sub(0x1D)
  local seq, err = Sseq.open(corrupted, "fixture")
  Assert.isNil(seq)
  Assert.isTrue(Errors.is(err))
  Assert.equal(asError(err).code, "SSEQ_BAD_DATA_OFFSET")
end

-- A variable-length operand running past the end of the file is truncated
-- data, not a slicing artifact.
function T.rejects_truncated_varlen_operand()
  local bytes, _ = SseqFixture.build({ { op = "note", key = 60, velocity = 96, duration = 1 } })
  local truncated = bytes:sub(1, #bytes - 2)
  rejects(truncated, "SSEQ_TRUNCATED")
end

return { tests = T }
