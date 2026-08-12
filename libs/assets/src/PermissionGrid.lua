-- Decoder for the HGSS land-data permission section: a 0x800-byte block of
-- 32x32 two-byte records. Byte 0 is the terrain/metatile behavior; byte 1 is a
-- packed movement value whose top bit (0x80) is the hard-block flag and whose
-- low 7 bits (0x7F) are a terrain/footstep response id -- NOT a plain collision
-- byte, so values like 4 and 6 are passable surface responses, not obstacles.
-- The split matches pret/pokeheartgold's field movement code, which tests bit
-- 15 of the u16 pair for blocking and masks the low 7 bits for the response.
-- Records are indexed exactly as the field engine does, z*32 + x, with no
-- transpose or vertical flip. Pure domain module; decode() returns
-- (grid | nil, err). Masks use plain arithmetic: for a byte, band(b, 0x80) ~= 0
-- is b >= 0x80, and band(b, 0x7F) is b % 0x80.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local PermissionGrid = {}
PermissionGrid.__index = PermissionGrid

-- Byte size of one permission grid (32x32 two-byte records). Exported at this
-- owner boundary: the digest writers (romdump MapCacheWriter) and the
-- cache-class readiness checks reference it instead of repeating 2048.
-- romdump's raw-side LandData keeps its own PERMISSIONS_SIZE for the ROM
-- format boundary; the two are the same value by contract, not one shared
-- constant (a ROM and a cache format must not be collapsed).
PermissionGrid.SIZE = 0x800

local WIDTH, HEIGHT = 32, 32
local HARD_BLOCK_FLAG = 0x80

local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

function PermissionGrid.decode(bytes, context)
  assert(type(bytes) == "string", "PermissionGrid.decode requires a string")
  if #bytes ~= PermissionGrid.SIZE then
    return nil,
      Errors.new(
        "PERMISSION_BAD_SIZE",
        "permission section must be " .. PermissionGrid.SIZE .. " bytes, got " .. #bytes,
        { size = #bytes, expected = PermissionGrid.SIZE, source = context }
      )
  end
  return setmetatable({
    _reader = BinaryReader.new(bytes, "permissions"),
    width = WIDTH,
    height = HEIGHT,
    source = context,
  }, PermissionGrid)
end

-- Cell coordinates are finite integers: a fractional coordinate would
-- otherwise read the shifted neighbouring record.
function PermissionGrid:contains(x, z)
  return finiteInteger(x) and finiteInteger(z) and x >= 0 and z >= 0 and x < WIDTH and z < HEIGHT
end

function PermissionGrid:get(x, z)
  if not self:contains(x, z) then
    Errors.raise(
      "PERMISSION_OUT_OF_BOUNDS",
      "local tile (" .. tostring(x) .. ", " .. tostring(z) .. ") outside 32x32 grid",
      { x = x, z = z }
    )
  end
  local offset = (z * WIDTH + x) * 2
  local behavior = self._reader:u8(offset)
  local permission = self._reader:u8(offset + 1)
  return {
    behavior = behavior,
    permissionRaw = permission,
    hardBlocked = permission >= HARD_BLOCK_FLAG,
    terrainResponseId = permission % HARD_BLOCK_FLAG,
    raw = behavior + permission * 256,
  }
end

-- Static permission-grid block flag only: the 0x80 bit. This is not the full
-- HGSS movement system (height/BDHC, special metatile behavior, objects, and
-- movement modes are all separate and deferred).
function PermissionGrid:isBlocked(x, z)
  return self:get(x, z).hardBlocked
end

local function usedValues(self, byteIndex)
  local seen = {}
  for index = 0, WIDTH * HEIGHT - 1 do
    seen[self._reader:u8(index * 2 + byteIndex)] = true
  end
  local out = {}
  for value in pairs(seen) do
    out[#out + 1] = value
  end
  table.sort(out)
  return out
end

-- Distinct terrain/metatile behavior bytes (byte 0), sorted.
function PermissionGrid:usedBehaviorValues()
  return usedValues(self, 0)
end
-- Distinct raw permission bytes (byte 1, hard-block bit + response id), sorted.
function PermissionGrid:usedPermissionValues()
  return usedValues(self, 1)
end

return PermissionGrid
