-- Bounded decoder for the NNS SSEQ command stream as the HGSS dump lays it
-- out and the ARM7 NitroSDK sequence player (SND_seq.c: TrackStepTicks,
-- TrackParseValue) interprets it: a u32 data offset at file offset 0x18, then
-- commands starting with an optional FE track-mask byte. Notes 0x00-0x7F
-- carry a velocity byte and a variable-length duration; 0x80-0x8F a
-- variable-length value; 0x90-0x9F branches (0x93 track+data-relative u24,
-- 0x94/0x95 data-relative u24)
-- and reserved forms; 0xA0 random / 0xA1 variable / 0xA2 conditional
-- prefixes; 0xB0-0xBF a var number plus u16; 0xC0-0xDF a u8; 0xE0-0xEF a
-- u16; 0xF0-0xFF nothing. Random operands (u16 lo, u16 hi) and variable
-- operands (u8 var number) normalize into {kind="random", lo, hi} and
-- {kind="variable", var} records; the random lo is the raw unsigned u16 word
-- and hi is its signed interpretation, and the lowering carries the pair
-- through verbatim (never a friendly min/max range). Every read is
-- bounds-checked; malformed data raises SSEQ_* errors, never slicing
-- artifacts. Pure domain module.

local Errors = require("libs.errors.src.Errors")

local Sseq = {}

Sseq.PREFIX_RANDOM = 0xA0
Sseq.PREFIX_VARIABLE = 0xA1
Sseq.PREFIX_IF = 0xA2

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

local function byteAt(bytes, offset, endPos, source)
  if offset >= endPos then
    fail("SSEQ_TRUNCATED", "command operand runs past the end of the sequence", {
      source = source,
      offset = offset,
    })
  end
  return string.byte(bytes, offset + 1)
end

-- Variable-length value: 7-bit groups, most significant first.
local function readVarlen(bytes, pos, endPos, source)
  local value = 0
  while pos < endPos do
    local byte = byteAt(bytes, pos, endPos, source)
    pos = pos + 1
    value = value * 128 + byte % 128
    if byte < 128 then
      return value, pos
    end
  end
  fail("SSEQ_TRUNCATED", "unterminated variable-length operand", {
    source = source,
    offset = pos,
  })
end

local function u16At(bytes, pos, endPos, source)
  return byteAt(bytes, pos, endPos, source) + byteAt(bytes, pos + 1, endPos, source) * 256
end

local function u24At(bytes, pos, endPos, source)
  return byteAt(bytes, pos, endPos, source)
    + byteAt(bytes, pos + 1, endPos, source) * 256
    + byteAt(bytes, pos + 2, endPos, source) * 65536
end

local function s16(value)
  if value >= 0x8000 then
    return value - 0x10000
  end
  return value
end

-- Parses a normalized operand: the plain encoding for the class (varlen/u8/
-- u16) or the prefixed random/variable encodings. Returns value, nextPos.
-- The random operand keeps the raw SDK pair: the first u16 as unsigned and
-- the second u16 as signed; the lowering carries the pair through verbatim.
local function parseValue(bytes, pos, endPos, mode, width, source)
  if mode == "random" then
    local lo = u16At(bytes, pos, endPos, source)
    local hi = s16(u16At(bytes, pos + 2, endPos, source))
    return { kind = "random", lo = lo, hi = hi }, pos + 4
  end
  if mode == "variable" then
    local var = byteAt(bytes, pos, endPos, source)
    return { kind = "variable", var = var }, pos + 1
  end
  if width == "varlen" then
    return readVarlen(bytes, pos, endPos, source)
  end
  if width == 8 then
    return byteAt(bytes, pos, endPos, source), pos + 1
  end
  return u16At(bytes, pos, endPos, source), pos + 2
end

-- Decodes one command at `offset`. Returns the command record
-- { offset, opcode, mode, conditional, next, ...class operands } or nil, err.
---@param bytes string
---@param offset integer
---@param endPos integer
---@param source string?
---@return table?|nil
---@return Errors.Error?|nil
local function decodeCommandImpl(bytes, offset, endPos, source)
  local mode = "plain"
  local conditional = false
  local pos = offset
  local cmd = byteAt(bytes, pos, endPos, source)
  pos = pos + 1
  if cmd == Sseq.PREFIX_IF then
    conditional = true
    cmd = byteAt(bytes, pos, endPos, source)
    pos = pos + 1
  end
  if cmd == Sseq.PREFIX_RANDOM then
    mode = "random"
    cmd = byteAt(bytes, pos, endPos, source)
    pos = pos + 1
  elseif cmd == Sseq.PREFIX_VARIABLE then
    mode = "variable"
    cmd = byteAt(bytes, pos, endPos, source)
    pos = pos + 1
  end

  local command = {
    offset = offset,
    opcode = cmd,
    mode = mode,
    conditional = conditional,
  }

  if cmd < 0x80 then
    -- note: velocity byte then the duration operand
    command.velocity = byteAt(bytes, pos, endPos, source)
    local duration
    duration, pos = parseValue(bytes, pos + 1, endPos, mode, "varlen", source)
    command.duration = duration
  elseif cmd <= 0x8F then
    local value
    value, pos = parseValue(bytes, pos, endPos, mode, "varlen", source)
    command.value = value
  elseif cmd <= 0x9F then
    if cmd == 0x93 then
      command.track = byteAt(bytes, pos, endPos, source)
      -- Nitro adds this operand to the sequence DATA payload base. Keep the
      -- raw relative value here; lowering rebases it before lookup.
      command.target = u24At(bytes, pos + 1, endPos, source)
      pos = pos + 4
    elseif cmd == 0x94 or cmd == 0x95 then
      command.target = u24At(bytes, pos, endPos, source)
      pos = pos + 3
    end
  elseif cmd <= 0xAF then
    -- reserved zero-operand forms
  elseif cmd <= 0xBF then
    command.var = byteAt(bytes, pos, endPos, source)
    local value
    value, pos = parseValue(bytes, pos + 1, endPos, mode, 16, source)
    command.value = value
  elseif cmd <= 0xDF then
    local value
    value, pos = parseValue(bytes, pos, endPos, mode, 8, source)
    command.value = value
  elseif cmd <= 0xEF then
    local value
    value, pos = parseValue(bytes, pos, endPos, mode, 16, source)
    command.value = value
  end

  command.next = pos
  return command
end

function Sseq.decodeCommand(bytes, offset, endPos, source)
  local ok, result = pcall(decodeCommandImpl, bytes, offset, endPos, source)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

local function _open(bytes, context)
  local source = context or "SSEQ"
  if #bytes < 0x1C then
    fail("SSEQ_TRUNCATED", "sequence is shorter than its data offset field", {
      source = source,
      actual = #bytes,
    })
  end
  local dataOffset = string.byte(bytes, 0x19)
    + string.byte(bytes, 0x1A) * 256
    + string.byte(bytes, 0x1B) * 65536
    + string.byte(bytes, 0x1C) * 16777216
  if dataOffset < 0x1C or dataOffset > #bytes then
    fail("SSEQ_BAD_DATA_OFFSET", "sequence data offset lies outside the file", {
      source = source,
      dataOffset = dataOffset,
      size = #bytes,
    })
  end
  return { dataOffset = dataOffset, source = source }
end

---@param bytes string
---@param context string?
---@return table?|nil
---@return Errors.Error?|nil
function Sseq.open(bytes, context)
  local ok, result = pcall(_open, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Sseq
