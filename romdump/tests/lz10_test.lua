-- LZ10 decoding contract: header, flag-bit semantics (clear = literal, set =
-- match), match length/displacement encoding, and strict typed rejection of
-- every malformed stream shape the decoder can meet: a missing flag byte, a
-- missing literal byte, a missing first or second match token byte, a match
-- reaching before the decoded start, and a match extending past the declared
-- output size. Vectors are built by hand from the GBATEK-documented scheme;
-- the real ROM gated the same semantics.

local Assert = require("tests.support.Assert")
local Lz10 = require("romdump.src.digest.Lz10")

local T = {}

local function lz10(size, body)
  return string.char(0x10, size % 256, math.floor(size / 256) % 256, math.floor(size / 65536) % 256) .. body
end

-- Flags 0x00: eight literals; stream "RGCN" plus four more bytes.
function T.header_and_literal_run()
  local data = lz10(8, string.char(0x00, 0x52, 0x47, 0x43, 0x4E, 0xFF, 0xFE, 0x01, 0x01))
  local out = assert(Lz10.decode(data))
  Assert.equal(out, "RGCN" .. string.char(0xFF, 0xFE, 0x01, 0x01))
end

-- Flag bit set = a match: first byte 0x00 (8 literals), second flag byte 0x01
-- (bit 0 set): the match reads the two following bytes as the token.
-- b1 = 0x44: length = 4 + 3 = 7, displacement = 4 * 256 + 0x01 + 1 = 1026 —
-- must reach the decoded prefix, so the stream decodes the previous literals
-- first. Build the body so the match copies from within the output.
function T.match_copies_from_the_decoded_prefix()
  -- 8 literals "ABCDEFGH", then flags 0x80 (bit 7 set) with token
  -- b1 = 0x00 (length 3, displacement high nibble 0), b2 = 0x02
  -- (displacement 0*256 + 2 + 1 = 3): copies output[dst-3 .. ] i.e. "FGH".
  local body = string.char(0x00, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x80, 0x00, 0x02)
  local data = lz10(11, body)
  local out = assert(Lz10.decode(data))
  Assert.equal(out, "ABCDEFGH" .. "FGH")
end

-- A run length longer than the displacement repeats the pattern (the DS
-- encoder emits such runs; the decoder must copy byte by byte).
function T.overlapping_matches_repeat_the_pattern()
  local body = string.char(0x22, 0x41, 0x42, 0x10, 0x01, 0x58, 0x59, 0x5A, 0x10, 0x01)
  -- flags 0x22 = 0b00100010: bits 7,6 clear = two literals "AB"; bit 5 set =
  -- match token (0x10,0x01): length 4, displacement 2, copying while
  -- overlapping ("AB" -> "ABAB"); bits 4..2 clear = literals "XYZ"; bit 1
  -- set starts a second match but the size cap stops at 8 output bytes.
  local data = lz10(8, body)
  local out = assert(Lz10.decode(data))
  Assert.equal(out, "ABABABXY")
end

function T.non_lz10_payload_is_rejected()
  local out, err = Lz10.decode("not-lz10")
  Assert.isNil(out)
  Assert.equal(assert(err).code, Lz10.ERROR.HEADER_INVALID)
end

-- A match whose displacement reaches before the decoded start is malformed
-- source, not an empty copy.
function T.match_before_output_start_is_rejected()
  local body = string.char(0x80, 0x00, 0x10)
  local data = lz10(4, body)
  local out, err = Lz10.decode(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

-- Every token location is bounds-checked: a stream that ends before its flag
-- byte must be a typed stream error, never a raw Lua indexing failure.
function T.missing_flag_byte_is_rejected()
  local out, err = Lz10.decode(lz10(1, ""))
  Assert.isNil(out)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

-- A flag byte promising a literal with no literal byte behind it.
function T.missing_literal_byte_is_rejected()
  local out, err = Lz10.decode(lz10(1, string.char(0x00)))
  Assert.isNil(out)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

-- A match flag with no token bytes at all.
function T.missing_first_match_byte_is_rejected()
  local out, err = Lz10.decode(lz10(1, string.char(0x80)))
  Assert.isNil(out)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

-- A match flag with only the first token byte: the displacement byte is
-- still required.
function T.missing_second_match_byte_is_rejected()
  local out, err = Lz10.decode(lz10(1, string.char(0x80, 0x10)))
  Assert.isNil(out)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

-- A match whose run length crosses the declared output size is malformed
-- source: the decoder must reject it instead of decoding extra bytes and
-- discarding them at concatenation.
function T.match_extending_beyond_output_size_is_rejected()
  -- Flags 0x10: three literals "ABC", then bit 4 set = a match with token
  -- (0x20, 0x00): length 5, displacement 1 — valid start at dst 4, but the
  -- run reaches output bytes 4..8 while the header declares 4.
  local body = string.char(0x10, 0x41, 0x42, 0x43, 0x20, 0x00)
  local out, err = Lz10.decode(lz10(4, body))
  Assert.isNil(out)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

return { tests = T }
