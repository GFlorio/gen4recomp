-- BinaryWriter little-endian output: independently authored wire bytes for
-- integer and IEEE-754 f32 encoding, raw byte append, and out-of-width integer
-- rejection.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
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

local function assertWriteError(fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, "WRITE_OUT_OF_RANGE")
end

-- Integer encoders must reject values outside the representable unsigned width
-- instead of silently wrapping via modulo.
function T.u8_rejects_out_of_width_values()
  assertWriteError(function()
    BinaryWriter.new():u8(-1)
  end)
  assertWriteError(function()
    BinaryWriter.new():u8(256)
  end)
  assertWriteError(function()
    BinaryWriter.new():u8(0.5)
  end)
  assertWriteError(function()
    BinaryWriter.new():u8(0 / 0)
  end)
  assertWriteError(function()
    BinaryWriter.new():u8(math.huge)
  end)
end

function T.u16_rejects_out_of_width_values()
  assertWriteError(function()
    BinaryWriter.new():u16(-1)
  end)
  assertWriteError(function()
    BinaryWriter.new():u16(65536)
  end)
  assertWriteError(function()
    BinaryWriter.new():u16(1.5)
  end)
  assertWriteError(function()
    BinaryWriter.new():u16(0 / 0)
  end)
end

function T.u32_rejects_out_of_width_values()
  assertWriteError(function()
    BinaryWriter.new():u32(-1)
  end)
  assertWriteError(function()
    BinaryWriter.new():u32(4294967296)
  end)
  assertWriteError(function()
    BinaryWriter.new():u32(0.5)
  end)
  assertWriteError(function()
    BinaryWriter.new():u32(-math.huge)
  end)
end

function T.integer_encoders_accept_the_full_width()
  local s = BinaryWriter.new():u8(0):u8(255):u16(0):u16(65535):u32(0):u32(4294967295):tostring()
  local r = BinaryReader.new(s, "bw")
  Assert.equal(r:u8(0), 0)
  Assert.equal(r:u8(1), 255)
  Assert.equal(r:u16le(2), 0)
  Assert.equal(r:u16le(4), 65535)
  Assert.equal(r:u32le(6), 0)
  Assert.equal(r:u32le(10), 4294967295)
end

return T
