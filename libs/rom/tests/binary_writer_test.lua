-- BinaryWriter little-endian output: independently authored wire bytes for
-- integer and IEEE-754 f32 encoding, plus raw byte append.

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.rom.src.BinaryWriter")

local T = {}

function T.integers_have_literal_little_endian_bytes()
  Assert.equal(
    BinaryWriter.new():u8(0x12):u16(0x3456):u32(0x89ABCDEF):tostring(),
    string.char(0x12, 0x56, 0x34, 0xEF, 0xCD, 0xAB, 0x89)
  )
end

function T.f32_has_literal_ieee_754_bytes()
  Assert.equal(
    BinaryWriter.new():f32(1.5):f32(-0.25):f32(0):tostring(),
    string.char(0x00, 0x00, 0xC0, 0x3F, 0x00, 0x00, 0x80, 0xBE, 0x00, 0x00, 0x00, 0x00)
  )
end

function T.f32_known_bit_pattern_for_1_5()
  -- 1.5 -> 0x3FC00000, little-endian bytes 00 00 C0 3F.
  Assert.equal(BinaryWriter.new():f32(1.5):tostring(), string.char(0x00, 0x00, 0xC0, 0x3F))
end

function T.f32_has_literal_geometry_bytes()
  -- -3.6234375 -> 0xC067E666, little-endian bytes 66 E6 67 C0.
  Assert.equal(BinaryWriter.new():f32(-3.6234375):tostring(), string.char(0x66, 0xE6, 0x67, 0xC0))
end

function T.bytes_appends_raw()
  Assert.equal(BinaryWriter.new():bytes("G4M1"):tostring(), "G4M1")
  Assert.equal(BinaryWriter.new():bytes("ab"):u8(0):length(), 3)
end

return T
