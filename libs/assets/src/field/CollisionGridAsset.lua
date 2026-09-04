-- The project-owned collision-grid binary asset ("G4CL"): a compact
-- row-major cell grid that any map tool can produce or consume without any
-- knowledge of HGSS permission packing. Header is magic "G4CL", u16 version,
-- u16 width, u16 height, then width*height cells of behavior u8,
-- terrainResponseId u8, blocked u8 (0 or 1). decode() is strict: bad magic,
-- unsupported version, zero dimensions, wrong total length, and non-0/1
-- blocked bytes are all malformed generated data. Pure domain module; the
-- encoding goes through the generic BinaryWriter so out-of-range fields are
-- rejected rather than wrapped.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local Contract = require("libs.assets.src.DerivedAssetContract")

local CollisionGridAsset = {}

CollisionGridAsset.MAGIC = "G4CL"
CollisionGridAsset.VERSION = Contract.map.collisionVersion

local HEADER_SIZE = 10 -- magic 4 + version 2 + width 2 + height 2

---@param code string
---@param message string
---@param context table<string, unknown>?
---@return nil, Errors.Error
local function fail(code, message, context)
  return nil, Errors.new(code, message, context)
end

-- Encode a normalized collision grid { width, height, cells } where each cell
-- is { behavior = u8, terrainResponseId = u8, blocked = boolean }. Raises on
-- malformed grids; returns the binary asset on success.
---@param grid { width: integer, height: integer, cells: table[] }
---@return string
function CollisionGridAsset.encode(grid)
  assert(type(grid) == "table" and type(grid.width) == "number" and type(grid.height) == "number", "grid required")
  assert(
    grid.width >= 1
      and grid.height >= 1
      and grid.width == math.floor(grid.width)
      and grid.height == math.floor(grid.height),
    "grid dimensions must be positive integers"
  )
  local cellCount = grid.width * grid.height
  assert(type(grid.cells) == "table" and #grid.cells == cellCount, "grid cells must match the grid dimensions")

  local writer = BinaryWriter.new()
  for index = 1, 4 do
    writer:u8(string.byte(CollisionGridAsset.MAGIC, index))
  end
  writer:u16(CollisionGridAsset.VERSION)
  writer:u16(grid.width)
  writer:u16(grid.height)
  for _, cell in ipairs(grid.cells) do
    assert(type(cell) == "table" and type(cell.blocked) == "boolean", "each collision cell needs blocked")
    writer:u8(cell.behavior)
    writer:u8(cell.terrainResponseId)
    writer:u8(cell.blocked and 1 or 0)
  end
  return writer:tostring()
end

-- Decode a G4CL asset into the normalized grid shape { width, height, cells }.
-- Returns (grid | nil, err) for malformed data.
---@param bytes string
---@param context table<string, unknown>|nil
---@return table<string, unknown>?, Errors.Error?
function CollisionGridAsset.decode(bytes, context)
  assert(type(bytes) == "string", "CollisionGridAsset.decode requires a string")
  if #bytes < HEADER_SIZE then
    return fail("COLLISION_BAD_SIZE", "collision asset is too short for its header", context)
  end
  local reader = BinaryReader.new(bytes, "g4collision")
  if reader:bytes(0, 4) ~= CollisionGridAsset.MAGIC then
    return fail("COLLISION_BAD_MAGIC", "collision asset has the wrong magic", context)
  end
  local version = reader:u16le(4)
  if version ~= CollisionGridAsset.VERSION then
    return fail(
      "COLLISION_BAD_VERSION",
      "collision asset version " .. version .. " is not supported",
      { version = version }
    )
  end
  local width = reader:u16le(6)
  local height = reader:u16le(8)
  if width < 1 or height < 1 then
    return fail("COLLISION_BAD_DIMENSIONS", "collision asset dimensions must be positive", {
      width = width,
      height = height,
    })
  end
  local cellCount = width * height
  if #bytes ~= HEADER_SIZE + cellCount * 3 then
    return fail(
      "COLLISION_BAD_SIZE",
      "collision asset length does not match its dimensions",
      { width = width, height = height, size = #bytes }
    )
  end

  local cells = {} ---@type table[]
  local offset = HEADER_SIZE
  for index = 0, cellCount - 1 do
    local blocked = reader:u8(offset + 2)
    if blocked ~= 0 and blocked ~= 1 then
      return fail("COLLISION_BAD_BLOCKED", "collision cell blocked byte is not 0 or 1", {
        index = index,
        value = blocked,
      })
    end
    cells[index + 1] = {
      behavior = reader:u8(offset),
      terrainResponseId = reader:u8(offset + 1),
      blocked = blocked == 1,
    }
    offset = offset + 3
  end
  return { width = width, height = height, cells = cells }
end

return CollisionGridAsset
