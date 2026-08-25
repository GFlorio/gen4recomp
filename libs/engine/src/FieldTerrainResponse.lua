-- Resolves a committed destination metatile into a presentation-only terrain
-- response. The resolver is pure and deliberately knows nothing about audio,
-- encounters, cache assets, or LÖVE.

local MetatileBehavior = require("libs.engine.src.MetatileBehavior")

local FieldTerrainResponse = {}

---@param movement { committed: boolean, destination: { behavior: integer, fieldX: integer, fieldZ: integer, worldY: number }, direction: string }
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
      direction = movement.direction,
    },
  }
end

return FieldTerrainResponse
