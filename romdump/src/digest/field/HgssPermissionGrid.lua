-- Decoder for the HGSS land-data permission section: a 0x800-byte block of
-- 32x32 two-byte records. Byte 0 is the terrain/metatile behavior; byte 1 is a
-- packed movement value whose top bit (0x80) is the hard-block flag and whose
-- low 7 bits (0x7F) are a terrain/footstep response id -- NOT a plain collision
-- byte, so values like 4 and 6 are passable surface responses, not obstacles.
-- The split matches pret/pokeheartgold's field movement code, which tests bit
-- 15 of the u16 pair for blocking and masks the low 7 bits for the response.
-- Records are indexed row-major z*32+x with no transpose or vertical flip,
-- exactly as the field engine does. decode() returns a normalized
-- { width, height, cells = { { behavior, terrainResponseId, blocked }, ... } }
-- grid; no consumer outside romdump sees the source packed byte or 0x80.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local HgssPermissionGrid = {}

-- Byte size of one permission grid (32x32 two-byte records), the raw-source
-- boundary constant for romdump digest writers and the LandData container.
HgssPermissionGrid.SIZE = 0x800

local WIDTH, HEIGHT = 32, 32
local HARD_BLOCK_FLAG = 0x80

local function usedValues(reader, byteIndex)
  local seen = {}
  for index = 0, WIDTH * HEIGHT - 1 do
    seen[reader:u8(index * 2 + byteIndex)] = true
  end
  local out = {}
  for value in pairs(seen) do
    out[#out + 1] = value
  end
  table.sort(out)
  return out
end

-- Decode a raw permission section into the normalized semantic grid. Returns
-- (grid | nil, err).
---@param bytes string
---@param context Errors.Context|nil
---@return table<string, unknown>?, Errors.Error?
function HgssPermissionGrid.decode(bytes, context)
  assert(type(bytes) == "string", "HgssPermissionGrid.decode requires a string")
  if #bytes ~= HgssPermissionGrid.SIZE then
    return nil,
      Errors.new(
        "PERMISSION_BAD_SIZE",
        "permission section must be " .. HgssPermissionGrid.SIZE .. " bytes, got " .. #bytes,
        { size = #bytes, expected = HgssPermissionGrid.SIZE, source = context }
      )
  end
  local reader = BinaryReader.new(bytes, "permissions")
  local cells = {}
  for index = 0, WIDTH * HEIGHT - 1 do
    local offset = index * 2
    local behavior = reader:u8(offset)
    local permission = reader:u8(offset + 1)
    cells[index + 1] = {
      behavior = behavior,
      terrainResponseId = permission % HARD_BLOCK_FLAG,
      blocked = permission >= HARD_BLOCK_FLAG,
    }
  end
  local grid = { width = WIDTH, height = HEIGHT, cells = cells }
  -- Source diagnostics used by the map inspector: distinct behavior bytes and
  -- distinct packed permission bytes, sorted. These are raw-source facts, so
  -- they live on the digest decoder and never cross into the collision asset.
  grid.usedBehaviorValues = usedValues(reader, 0)
  grid.usedPermissionValues = usedValues(reader, 1)
  return grid
end

return HgssPermissionGrid
