-- Composes one runtime map cell and its cached neighboring cells into a single
-- collision and terrain view. Coordinates remain local to the central cell;
-- neighboring BDHC planes are translated in all three axes.

local TerrainSurface = require("libs.engine.src.TerrainSurface")

local FieldRegion = {}

local function copyPlate(plate, id, offsetX, offsetY, offsetZ, cellKey)
  local copy = {}
  for key, value in pairs(plate) do
    copy[key] = value
  end
  copy.id = id
  copy.sourceSurfaceId = plate.id
  copy.cellKey = cellKey
  copy.cellOffsetX = offsetX
  copy.cellOffsetY = offsetY
  copy.cellOffsetZ = offsetZ
  copy.minX = plate.minX + offsetX
  copy.maxX = plate.maxX + offsetX
  copy.minZ = plate.minZ + offsetZ
  copy.maxZ = plate.maxZ + offsetZ
  copy.normal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z }
  copy.distance = plate.distance + plate.normal.x * offsetX + plate.normal.y * offsetY + plate.normal.z * offsetZ
  return copy
end

local function collisionRegion(cells)
  local collision = {}

  local function cellAt(localX, localZ)
    for _, cell in ipairs(cells) do
      local x, z = localX - cell.offsetTilesX, localZ - cell.offsetTilesZ
      if cell.collision:containsLocal(x, z) then
        return cell, x, z
      end
    end
    return nil
  end

  function collision:containsLocal(localX, localZ)
    return cellAt(localX, localZ) ~= nil
  end

  function collision:getLocal(localX, localZ)
    local cell, x, z = cellAt(localX, localZ)
    assert(cell, "field coordinate outside composed region")
    local result = cell.collision:getLocal(x, z)
    result.cellKey = cell.key
    return result
  end

  function collision:isBlockedLocal(localX, localZ)
    local cell, x, z = cellAt(localX, localZ)
    assert(cell, "field coordinate outside composed region")
    return cell.collision:isBlockedLocal(x, z)
  end

  return collision
end

function FieldRegion.new(centralCollision, centralTerrain, neighbors, centralKey, surfaceIdBase)
  assert(centralCollision and centralCollision.containsLocal, "central collision grid required")
  assert(centralTerrain and centralTerrain.plates, "central terrain surfaces required")

  local cells = {
    {
      offsetTilesX = 0,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      collision = centralCollision,
      terrain = centralTerrain,
      key = centralKey,
    },
  }
  for _, neighbor in ipairs(neighbors or {}) do
    assert(neighbor.collision and neighbor.terrain, "neighbor collision and terrain required")
    assert(type(neighbor.offsetTilesX) == "number", "neighbor X offset required")
    assert(type(neighbor.offsetTilesY) == "number", "neighbor Y offset required")
    assert(type(neighbor.offsetTilesZ) == "number", "neighbor Z offset required")
    cells[#cells + 1] = neighbor
  end

  local plates, nextSurfaceId = {}, surfaceIdBase or 0
  for _, plate in ipairs(centralTerrain.plates) do
    plates[#plates + 1] = copyPlate(plate, nextSurfaceId, 0, 0, 0, cells[1].key)
    nextSurfaceId = nextSurfaceId + 1
  end
  for index = 2, #cells do
    local cell = cells[index]
    for _, plate in ipairs(cell.terrain.plates) do
      plates[#plates + 1] =
        copyPlate(plate, nextSurfaceId, cell.offsetTilesX, cell.offsetTilesY, cell.offsetTilesZ, cell.key)
      nextSurfaceId = nextSurfaceId + 1
    end
  end

  return {
    collision = collisionRegion(cells),
    terrain = TerrainSurface.new({ schema = "g4-composite-terrain-v1", plates = plates }),
    cells = cells,
    sourceSurface = function(self, cellKey, sourceSurfaceId)
      for _, plate in ipairs(self.terrain.plates) do
        if plate.cellKey == cellKey and plate.sourceSurfaceId == sourceSurfaceId then
          return plate.id
        end
      end
      return nil
    end,
  }
end

return FieldRegion
