-- Converts authoritative global field coordinates to the currently loaded
-- permission cell and centered render space. Player, camera, warp, and save
-- code share this boundary so matrix-origin arithmetic cannot diverge.

local Errors = require("libs.rom.src.Errors")
local FieldGrid = require("libs.engine.src.FieldGrid")

local FieldCoordinates = {}

local function origin(runtimeMap)
  assert(runtimeMap and runtimeMap.coordinateOrigin, "runtime map coordinate origin required")
  return runtimeMap.coordinateOrigin.x, runtimeMap.coordinateOrigin.z
end

local function requireLocal(runtimeMap, localX, localZ, context)
  assert(runtimeMap.permissions and runtimeMap.permissions.containsLocal,
    "runtime map permission coverage required")
  if not runtimeMap.permissions:containsLocal(localX, localZ) then
    context = context or {}
    context.localX, context.localZ = localX, localZ
    context.mapId = runtimeMap.mapId
    Errors.raise("FIELD_COORDINATES_OUT_OF_COVERAGE",
      string.format("coordinate (%s,%s) is outside map %s permission coverage",
        tostring(localX), tostring(localZ), tostring(runtimeMap.mapId)), context)
  end
end

function FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  assert(type(fieldX) == "number" and type(fieldZ) == "number", "field coordinates must be numbers")
  local originX, originZ = origin(runtimeMap)
  local localX, localZ = fieldX - originX, fieldZ - originZ
  requireLocal(runtimeMap, localX, localZ, { fieldX = fieldX, fieldZ = fieldZ })
  return localX, localZ
end

function FieldCoordinates.localToField(runtimeMap, localX, localZ)
  assert(type(localX) == "number" and type(localZ) == "number", "local coordinates must be numbers")
  requireLocal(runtimeMap, localX, localZ)
  local originX, originZ = origin(runtimeMap)
  return localX + originX, localZ + originZ
end

function FieldCoordinates.fieldToWorld(runtimeMap, fieldX, fieldZ, worldY)
  assert(type(worldY) == "number", "world Y must be a number")
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local worldX, worldZ = FieldGrid.tileCenterToWorld(localX, localZ)
  return { x = worldX, y = worldY, z = worldZ }
end

return FieldCoordinates
