-- Little-endian byte builder for generated binary assets (the G4M2 mesh format).
-- The mirror of BinaryReader: integers are assembled arithmetically and 32-bit
-- floats are encoded to IEEE-754 single precision by hand, since LuaJIT/5.1 has
-- no string.pack. Keeping the encoder pure (no love, no bit ops) makes generated
-- output deterministic across platforms. Pure domain module.

local BinaryWriter = {}
BinaryWriter.__index = BinaryWriter

function BinaryWriter.new()
  return setmetatable({ _chunks = {}, _len = 0 }, BinaryWriter)
end

local function push(self, s)
  self._chunks[#self._chunks + 1] = s
  self._len = self._len + #s
  return self
end

function BinaryWriter:u8(v)
  return push(self, string.char(v % 256))
end

function BinaryWriter:u16(v)
  return push(self, string.char(v % 256, math.floor(v / 256) % 256))
end

function BinaryWriter:u32(v)
  return push(self, string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256))
end

-- IEEE-754 binary32, little-endian. Handles zero, infinity, NaN, and normals;
-- subnormal inputs are rounded to the nearest representable value.
function BinaryWriter:f32(v)
  local neg = false
  if v ~= v then -- NaN
    return push(self, string.char(0x00, 0x00, 0xC0, 0x7F))
  end
  if v < 0 or (v == 0 and 1 / v == -math.huge) then neg = true; v = -v end
  local sign = neg and 2147483648 or 0 -- bit 31
  if v == math.huge then
    return self:u32(sign + 255 * 8388608)
  end
  if v == 0 then
    return self:u32(sign)
  end
  local mant, expo = math.frexp(v) -- v = mant * 2^expo, 0.5 <= mant < 1
  local biased = (expo - 1) + 127
  local mantissa
  if biased <= 0 then -- subnormal / underflow
    mantissa = math.floor(v / 2 ^ -149 + 0.5)
    biased = 0
    if mantissa >= 8388608 then biased = 1; mantissa = mantissa - 8388608 end
  else
    mantissa = math.floor((mant * 2 - 1) * 8388608 + 0.5)
    if mantissa >= 8388608 then -- mantissa rounded up into the next exponent
      mantissa = 0
      biased = biased + 1
    end
    if biased >= 255 then return self:u32(sign + 255 * 8388608) end
  end
  return self:u32(sign + biased * 8388608 + mantissa)
end

function BinaryWriter:bytes(s)
  return push(self, s)
end

function BinaryWriter:length()
  return self._len
end

function BinaryWriter:tostring()
  return table.concat(self._chunks)
end

return BinaryWriter
