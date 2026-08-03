-- Decoder for the HGSS land-data permission section: a 0x800-byte block of
-- 32x32 two-byte records. Byte 0 is the terrain/metatile behavior, byte 1 the
-- movement/collision value. Records are indexed exactly as the field engine
-- does, z*32 + x, with no transpose or vertical flip. Pure domain module;
-- decode() returns (grid | nil, err). Collision tests use plain arithmetic:
-- for a byte, band(c, 0x80) ~= 0 is equivalent to c >= 0x80.

local Errors = require("src.import.Errors")
local BinaryReader = require("src.import.BinaryReader")

local PermissionGrid = {}
PermissionGrid.__index = PermissionGrid

local WIDTH, HEIGHT = 32, 32
local SIZE = 0x800
local IMPASSABLE_FLAG = 0x80

function PermissionGrid.decode(bytes, context)
  assert(type(bytes) == "string", "PermissionGrid.decode requires a string")
  if #bytes ~= SIZE then
    return nil, Errors.new("PERMISSION_BAD_SIZE",
      "permission section must be " .. SIZE .. " bytes, got " .. #bytes,
      { size = #bytes, expected = SIZE, source = context })
  end
  return setmetatable({
    _reader = BinaryReader.new(bytes, "permissions"),
    width = WIDTH,
    height = HEIGHT,
    source = context,
  }, PermissionGrid)
end

function PermissionGrid:contains(x, z)
  return type(x) == "number" and type(z) == "number"
    and x >= 0 and z >= 0 and x < WIDTH and z < HEIGHT
end

function PermissionGrid:get(x, z)
  if not self:contains(x, z) then
    Errors.raise("PERMISSION_OUT_OF_BOUNDS",
      "local tile (" .. tostring(x) .. ", " .. tostring(z) .. ") outside 32x32 grid",
      { x = x, z = z })
  end
  local offset = (z * WIDTH + x) * 2
  local terrain = self._reader:u8(offset)
  local collision = self._reader:u8(offset + 1)
  return { terrain = terrain, collision = collision, raw = terrain + collision * 256 }
end

-- Returns (blocked, reason). The initial policy: 0x00 is passable, the 0x80 bit
-- is impassable, any other nonzero value is blocked in strict mode (default)
-- and always reported with its raw value so unexpected data is never silently
-- treated as passable.
function PermissionGrid:isBlocked(x, z, policy)
  local strict = not (policy and policy.strict == false)
  local collision = self:get(x, z).collision
  if collision == 0 then
    return false, nil
  end
  if collision >= IMPASSABLE_FLAG then
    return true, string.format("impassable-flag:0x%02X", collision)
  end
  return strict, string.format("unknown-collision:0x%02X", collision)
end

local function usedValues(self, byteIndex)
  local seen = {}
  for index = 0, WIDTH * HEIGHT - 1 do
    seen[self._reader:u8(index * 2 + byteIndex)] = true
  end
  local out = {}
  for value in pairs(seen) do out[#out + 1] = value end
  table.sort(out)
  return out
end

function PermissionGrid:usedTerrainValues() return usedValues(self, 0) end
function PermissionGrid:usedCollisionValues() return usedValues(self, 1) end

return PermissionGrid
