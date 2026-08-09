-- Composes one runtime map cell and its cached neighboring cells into a single
-- permission and terrain view. Coordinates remain local to the central cell;
-- neighboring BDHC planes are translated without changing sampled height.

local TerrainSurface = require("libs.engine.src.TerrainSurface")

local FieldRegion = {}

local function copyPlate(plate, id, offsetX, offsetZ)
  local copy = {}
  for key, value in pairs(plate) do
    copy[key] = value
  end
  copy.id = id
  copy.sourceSurfaceId = plate.id
  copy.cellOffsetX = offsetX
  copy.cellOffsetZ = offsetZ
  copy.minX = plate.minX + offsetX
  copy.maxX = plate.maxX + offsetX
  copy.minZ = plate.minZ + offsetZ
  copy.maxZ = plate.maxZ + offsetZ
  copy.normal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z }
  copy.distance = plate.distance + plate.normal.x * offsetX + plate.normal.z * offsetZ
  return copy
end

local function collisionRegion(cells)
  local permissions = {}

  local function cellAt(localX, localZ)
    for _, cell in ipairs(cells) do
      local x, z = localX - cell.offsetTilesX, localZ - cell.offsetTilesZ
      if cell.collision:containsLocal(x, z) then
        return cell, x, z
      end
    end
    return nil
  end

  function permissions:containsLocal(localX, localZ)
    return cellAt(localX, localZ) ~= nil
  end

  function permissions:getLocal(localX, localZ)
    local cell, x, z = cellAt(localX, localZ)
    assert(cell, "field coordinate outside composed region")
    return cell.collision:getLocal(x, z)
  end

  function permissions:isBlockedLocal(localX, localZ)
    local cell, x, z = cellAt(localX, localZ)
    assert(cell, "field coordinate outside composed region")
    return cell.collision:isBlockedLocal(x, z)
  end

  return permissions
end

function FieldRegion.new(centralCollision, centralTerrain, neighbors)
  assert(centralCollision and centralCollision.containsLocal, "central collision grid required")
  assert(centralTerrain and centralTerrain.plates, "central terrain surfaces required")

  local cells = {
    {
      offsetTilesX = 0,
      offsetTilesZ = 0,
      collision = centralCollision,
      terrain = centralTerrain,
    },
  }
  for _, neighbor in ipairs(neighbors or {}) do
    assert(neighbor.collision and neighbor.terrain, "neighbor collision and terrain required")
    cells[#cells + 1] = neighbor
  end

  local plates, maxSurfaceId = {}, -1
  for _, plate in ipairs(centralTerrain.plates) do
    plates[#plates + 1] = copyPlate(plate, plate.id, 0, 0)
    maxSurfaceId = math.max(maxSurfaceId, plate.id)
  end
  local nextSurfaceId = maxSurfaceId + 1
  for index = 2, #cells do
    local cell = cells[index]
    for _, plate in ipairs(cell.terrain.plates) do
      plates[#plates + 1] = copyPlate(plate, nextSurfaceId, cell.offsetTilesX, cell.offsetTilesZ)
      nextSurfaceId = nextSurfaceId + 1
    end
  end

  return {
    permissions = collisionRegion(cells),
    terrain = TerrainSurface.new({ schema = "g4-composite-terrain-v1", plates = plates }),
    cells = cells,
  }
end

return FieldRegion
