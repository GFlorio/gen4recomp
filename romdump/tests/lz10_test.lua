-- LZ10 decoding contract: header, flag-bit semantics (clear = literal, set =
-- match), match length/displacement encoding, and strict rejection of
-- truncated or out-of-bounds streams. Vectors are built by hand from the
-- GBATEK-documented scheme; the real ROM gated the same semantics.

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
  Assert.equal(assert(err).code, "LZ10_HEADER_INVALID")
end

-- A match whose displacement reaches before the decoded start is malformed
-- source, not an empty copy.
function T.match_before_output_start_is_rejected()
  local body = string.char(0x80, 0x00, 0x10)
  local data = lz10(4, body)
  local out, err = Lz10.decode(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, "LZ10_STREAM_INVALID")
end

return { tests = T }
