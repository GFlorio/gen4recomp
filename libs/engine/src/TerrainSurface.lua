-- Runtime index over normalized BDHC plates. It answers horizontal containment
-- and evaluates the authoritative gameplay plane; permission/collision policy
-- deliberately remains outside this pure domain module.

---@class TerrainSurface
---@field artifact table
---@field plates table[]
---@field plateById table<integer, table>
local TerrainSurface = {}
TerrainSurface.__index = TerrainSurface


local CONTAINMENT_EPSILON = 1e-9

function TerrainSurface.new(artifact)
  assert(type(artifact) == "table" and type(artifact.plates) == "table",
    "TerrainSurface.new requires a terrain artifact")
  local plateById = {}
  for _, plate in ipairs(artifact.plates) do
    assert(plateById[plate.id] == nil, "duplicate terrain surface id")
    plateById[plate.id] = plate
  end
  return setmetatable({ artifact = artifact, plates = artifact.plates, plateById = plateById }, TerrainSurface)
end

function TerrainSurface:plate(surfaceId)
  return self.plateById[surfaceId]
end

function TerrainSurface:contains(surfaceId, localX, localZ)
  local plate = self.plateById[surfaceId]
  if not plate then return false end
  return localX >= plate.minX - CONTAINMENT_EPSILON
    and localX <= plate.maxX + CONTAINMENT_EPSILON
    and localZ >= plate.minZ - CONTAINMENT_EPSILON
    and localZ <= plate.maxZ + CONTAINMENT_EPSILON
end

function TerrainSurface:candidatesAt(localX, localZ)
  assert(type(localX) == "number" and type(localZ) == "number", "candidate coordinates must be numbers")
  local candidates = {}
  -- Full scans are intentional until strip boundary semantics are verified.
  for _, plate in ipairs(self.plates) do
    if plate.walkable ~= false and self:contains(plate.id, localX, localZ) then
      candidates[#candidates + 1] = plate
    end
  end
  return candidates
end

function TerrainSurface:sampleHeight(surfaceId, localX, localZ)
  local plate = assert(self.plateById[surfaceId], "unknown terrain surface id")
  local normal = plate.normal
  assert(plate.walkable ~= false and normal.y ~= 0, "terrain surface must be walkable")
  return (plate.distance - normal.x * localX - normal.z * localZ) / normal.y
end

function TerrainSurface:sample(surfaceId, localX, localZ)
  local plate = assert(self.plateById[surfaceId], "unknown terrain surface id")
  return {
    surfaceId = surfaceId,
    worldY = self:sampleHeight(surfaceId, localX, localZ),
    normal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z },
    slopeClass = plate.slopeClass,
  }
end

return TerrainSurface
