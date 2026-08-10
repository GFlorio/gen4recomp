-- BinaryWriter little-endian output: integer round-trips through BinaryReader,
-- IEEE-754 f32 round-trip (including a fractional and negative value), and raw
-- byte append.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local BinaryWriter = require("libs.rom.src.BinaryWriter")

local T = {}

local function assertWriteError(fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, "WRITE_OUT_OF_RANGE")
end

function T.integers_roundtrip_little_endian()
  local s = BinaryWriter.new():u8(0x12):u16(0x3456):u32(0x89ABCDEF):tostring()
  local r = BinaryReader.new(s, "bw")
  Assert.equal(r:u8(0), 0x12)
  Assert.equal(r:u16le(1), 0x3456)
  Assert.equal(r:u32le(3), 0x89ABCDEF)
  Assert.equal(#s, 7)
end

function T.f32_roundtrips_representable_values()
  local s = BinaryWriter.new():f32(1.5):f32(-0.25):f32(0):tostring()
  local r = BinaryReader.new(s, "bw")
  Assert.isTrue(math.abs(r:f32le(0) - 1.5) < 1e-12, "1.5")
  Assert.isTrue(math.abs(r:f32le(4) - -0.25) < 1e-12, "-0.25")
  Assert.equal(r:f32le(8), 0)
end

function T.f32_known_bit_pattern_for_1_5()
  -- 1.5 -> 0x3FC00000, little-endian bytes 00 00 C0 3F.
  local r = BinaryReader.new(BinaryWriter.new():f32(1.5):tostring(), "bw")
  Assert.equal(r:u32le(0), 0x3FC00000)
end

function T.f32_roundtrips_arbitrary_geometry_value()
  local v = -3.6234375 -- exactly representable in binary32
  local r = BinaryReader.new(BinaryWriter.new():f32(v):tostring(), "bw")
  Assert.isTrue(math.abs(r:f32le(0) - v) < 1e-6, "geometry value")
end

function T.bytes_appends_raw()
  Assert.equal(BinaryWriter.new():bytes("G4M1"):tostring(), "G4M1")
  Assert.equal(BinaryWriter.new():bytes("ab"):u8(0):length(), 3)
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
