-- Test helper: assemble SSEQ embedded-resource bytes from a small command
-- DSL. Layout follows the NNS SSEQ as the HGSS dump lays it out: a 16-byte
-- NNS file header, a DATA block header, a u32 data offset, then the command
-- stream beginning with an optional FE track-mask byte. Command records are
-- tables; the op selects the encoding and remaining fields are operands:
--   { op = "note", key = 60, velocity = 96, duration = <int|random|variable> }
--   { op = "wait", duration = <int|random|variable> }
--   { op = "program", program = <int|random|variable> }
--   { op = "fe", mask = 0b... }            -- 0xFE + u16 track mask
--   { op = "open_track", track = n, target = offset | { cmd = n } }
--   { op = "jump"|"call", target = offset | { cmd = n } }
--   { op = "ret" } { op = "fin" } { op = "nop_op" }
--   { op = "setvar", var = n, amount = <int|random|variable> } (and the
--     addvar/subvar/mulvar/divvar/shiftvar/randomvar/cmp_* siblings)
--   { op = "u8", command = 0xC0, amount = <int|random|variable> }   (0xC0-0xDF)
--   { op = "u16", command = 0xE1, amount = <int|random|variable> }  (0xE0-0xEF)
--   { op = "prefix", kind = "random"|"variable"|"if", command = {...} }
--   { op = "raw", bytes = "..." }
-- `random` operands are { kind = "random", lo =, hi = } or the legacy
-- { kind = "random", min =, max = } (u16 pair, signed; lo/min encodes the
-- first word, hi/max the second); `variable` operands are
-- { kind = "variable", var = n } (u8 after the A1 prefix). build() returns
-- bytes, layout where layout.offsets[i] is the file
-- offset of command i (1-based, over the whole file including the wrapper)
-- and layout.dataOffset the decoded data offset. Test-only fixture.

local FntWriter = require("tests.support.FntWriter")

local SseqFixture = {}

local function u8(v)
  return string.char(v % 256)
end
local u16, u32 = FntWriter.u16, FntWriter.u32

local function u24(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256)
end

local function varlen(value)
  assert(value >= 0, "varlen values are non-negative")
  local parts = { string.char(value % 128) }
  value = math.floor(value / 128)
  while value > 0 do
    table.insert(parts, 1, string.char(128 + value % 128))
    value = math.floor(value / 128)
  end
  return table.concat(parts)
end

local function s16(value)
  if value < 0 then
    return value + 0x10000
  end
  return value
end

-- Encodes a normalized value: plain integer (u16), random (u16 lo, u16 hi),
-- or variable (u8 var number).
local function encodeAmount(value, width)
  if type(value) == "number" then
    if width == 8 then
      return u8(value)
    end
    return u16(value)
  end
  assert(type(value) == "table", "amount must be an integer or a record")
  if value.kind == "random" then
    local lo, hi
    if value.lo ~= nil then
      lo, hi = value.lo, value.hi
    else
      lo, hi = value.min, value.max
    end
    return u16(s16(lo)) .. u16(s16(hi))
  end
  assert(value.kind == "variable", "unknown amount kind " .. tostring(value.kind))
  return u8(value.var)
end

local VAR_OPS = {
  setvar = 0xB0,
  addvar = 0xB1,
  subvar = 0xB2,
  mulvar = 0xB3,
  divvar = 0xB4,
  shiftvar = 0xB5,
  randomvar = 0xB6,
  cmp_eq = 0xB8,
  cmp_ge = 0xB9,
  cmp_gt = 0xBA,
  cmp_le = 0xBB,
  cmp_lt = 0xBC,
  cmp_ne = 0xBD,
}

-- Resolves a branch target: a plain offset passes through; a {cmd = n}
-- record resolves to the file offset of command n (known from the first
-- build pass). Targets are always u24, so both passes encode identically;
-- the first pass resolves symbolic targets to zero.
local function resolveTarget(value, offsets)
  if type(value) == "table" then
    assert(value.cmd ~= nil, "symbolic targets need a cmd index")
    if offsets == nil then
      return 0
    end
    return assert(offsets[value.cmd], "no command " .. value.cmd .. " in the fixture layout")
  end
  return value
end

local function commandBytes(cmd, offsets)
  local op = cmd.op
  if op == "note" then
    local duration = cmd.duration
    if type(duration) == "table" then
      if duration.kind == "random" then
        return u8(cmd.key) .. u8(cmd.velocity) .. encodeAmount(duration, 16)
      end
      return u8(cmd.key) .. u8(cmd.velocity) .. u8(duration.var)
    end
    return u8(cmd.key) .. u8(cmd.velocity) .. varlen(duration)
  end
  if op == "wait" then
    local duration = cmd.duration
    if type(duration) == "table" then
      return u8(0x80) .. encodeAmount(duration, 16)
    end
    return u8(0x80) .. varlen(duration)
  end
  if op == "program" then
    local program = cmd.program
    if type(program) == "table" then
      return u8(0x81) .. encodeAmount(program, 16)
    end
    return u8(0x81) .. varlen(program)
  end
  if op == "fe" then
    return u8(0xFE) .. u16(cmd.mask)
  end
  if op == "open_track" then
    return u8(0x93) .. u8(cmd.track) .. u24(resolveTarget(cmd.target, offsets))
  end
  if op == "jump" then
    return u8(0x94) .. u24(resolveTarget(cmd.target, offsets))
  end
  if op == "call" then
    return u8(0x95) .. u24(resolveTarget(cmd.target, offsets))
  end
  if op == "ret" then
    return u8(0xFD)
  end
  if op == "fin" then
    return u8(0xFF)
  end
  if op == "nop_op" then
    local cmd = cmd.command or 0xFE
    -- The 0x80-0x8F class consumes a variable-length operand even for
    -- reserved commands; every other reserved form is zero-operand.
    if cmd >= 0x80 and cmd <= 0x8F then
      return u8(cmd) .. varlen(0)
    end
    return u8(cmd)
  end
  if VAR_OPS[op] then
    return u8(VAR_OPS[op]) .. u8(cmd.var) .. encodeAmount(cmd.amount, 16)
  end
  if op == "u8" then
    return u8(cmd.command) .. encodeAmount(cmd.amount, 8)
  end
  if op == "u16" then
    return u8(cmd.command) .. encodeAmount(cmd.amount, 16)
  end
  if op == "prefix" then
    local kind = cmd.kind
    local prefix = kind == "random" and 0xA0 or (kind == "variable" and 0xA1 or 0xA2)
    return u8(prefix) .. commandBytes(cmd.command)
  end
  if op == "raw" then
    return cmd.bytes
  end
  error("unknown fixture command op " .. tostring(op))
end

-- Builds the full embedded SSEQ file bytes (NNS header + DATA block +
-- content with the u32 data offset and the command stream). Two passes:
-- the first computes command offsets (all targets resolve against it), the
-- second emits the bytes with symbolic targets resolved.
---@param commands table[]
---@return string
---@return table
function SseqFixture.build(commands)
  local offsets = {}
  local cursor = 0x1C
  for index, cmd in ipairs(commands) do
    offsets[index] = cursor
    cursor = cursor + #commandBytes(cmd, nil)
  end
  local body = {}
  for index, cmd in ipairs(commands) do
    body[index] = commandBytes(cmd, offsets)
  end
  local content = u32(0x1C) .. table.concat(body)
  local dataBlock = "DATA" .. u32(#content + 8) .. content
  local file = "SSEQ" .. u16(0xFEFF) .. u16(0x0100) .. u32(16 + #dataBlock) .. u16(0x10) .. u16(1) .. dataBlock
  return file, { offsets = offsets, dataOffset = 0x1C }
end

-- Overwrites the u24 at `offset` (a little-endian 24-bit value).
function SseqFixture.patchU24(bytes, offset, value)
  return bytes:sub(1, offset)
    .. string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256)
    .. bytes:sub(offset + 4)
end

return SseqFixture
