-- Resolves a committed destination metatile into a presentation-only terrain
-- response. The resolver is pure and deliberately knows nothing about audio,
-- encounters, cache assets, or LÖVE.

local MetatileBehavior = require("libs.hgss.src.field.MetatileBehavior")

local FieldTerrainResponse = {}

---@param movement { committed: boolean, destination: { behavior: integer, fieldX: integer, fieldZ: integer, worldY: number, cellKey: string?, sourceCellKey: string?, sourceSurfaceId: integer? }, direction: string }
---@return table[]
function FieldTerrainResponse.resolve(movement)
  assert(type(movement) == "table", "terrain movement is required")
  if not movement.committed then
    return {}
  end
  local destination = assert(movement.destination, "committed terrain destination is required")
  local kind
  if MetatileBehavior.isTallGrass(destination.behavior) then
    kind = "tall_grass"
  elseif MetatileBehavior.isVeryTallGrass(destination.behavior) then
    kind = "very_tall_grass"
  end
  if not kind then
    return {}
  end
  return {
    {
      kind = kind,
      fieldX = destination.fieldX,
      fieldZ = destination.fieldZ,
      worldY = destination.worldY,
      cellKey = destination.cellKey or destination.sourceCellKey,
      sourceSurfaceId = destination.sourceSurfaceId,
    },
  }
end

return FieldTerrainResponse
