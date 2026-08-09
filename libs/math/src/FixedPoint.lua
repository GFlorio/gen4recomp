-- Fixed-point and packed-value helpers for the Nitro 3D formats. Pure domain
-- module: no love dependency, no bit library. All field extraction is plain
-- arithmetic, which is exact for the 10/16/32-bit values these formats use
-- under LuaJIT doubles. Conventions follow GBATEK's "DS 3D" section: DS fixed
-- point is 1.M.12 (both fx16 and fx32 divide by 4096), normals are 1.0.9
-- packed 10-bit triples, colors are BGR555, angles use 0x10000 == 360 degrees.

local FixedPoint = {}

local TWO_PI = 2 * math.pi

-- Sign-extend an n-bit unsigned integer to a signed Lua number.
local function signExtend(value, bits)
  local half = 2 ^ (bits - 1)
  if value >= half then
    return value - 2 ^ bits
  end
  return value
end

-- Signed 20.12 (fx32) -> real number. Input is the raw unsigned 32-bit word.
function FixedPoint.fx32(value)
  return signExtend(value, 32) / 4096
end

-- Signed 3.12 (fx16) -> real number. Input is the raw unsigned 16-bit word.
function FixedPoint.fx16(value)
  return signExtend(value, 16) / 4096
end

-- Sign-extend a 10-bit integer (0..1023) to -512..511.
function FixedPoint.s10(value)
  return signExtend(value, 10)
end

-- Unpack a NORMAL command word: three signed 10-bit 1.0.9 components at bits
-- 0-9, 10-19, 20-29. Returns nx, ny, nz in -1..~1 (component / 512).
function FixedPoint.normal10(word)
  local x = word % 1024
  local y = math.floor(word / 1024) % 1024
  local z = math.floor(word / 1048576) % 1024
  return FixedPoint.s10(x) / 512, FixedPoint.s10(y) / 512, FixedPoint.s10(z) / 512
end

-- BGR555 -> r, g, b each 0..255. Bits 0-4 red, 5-9 green, 10-14 blue. The high
-- bit is ignored here; callers decide alpha per format.
function FixedPoint.rgb555(value)
  local r5 = value % 32
  local g5 = math.floor(value / 32) % 32
  local b5 = math.floor(value / 1024) % 32
  return math.floor(r5 * 255 / 31 + 0.5), math.floor(g5 * 255 / 31 + 0.5), math.floor(b5 * 255 / 31 + 0.5)
end

-- DS angle word (0x10000 == full turn) -> radians.
function FixedPoint.angle16(value)
  return value * TWO_PI / 65536
end

return FixedPoint
