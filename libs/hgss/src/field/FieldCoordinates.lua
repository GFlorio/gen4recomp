-- Converts authoritative global field coordinates to the currently loaded
-- permission cell and centered render space. Player, camera, warp, and save
-- code share this boundary so matrix-origin arithmetic cannot diverge.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")

local FieldCoordinates = {}

-- Half-tile offset from a local tile index to its centre, where terrain is
-- sampled and surfaces are resolved throughout the field runtime.
FieldCoordinates.TILE_CENTER_OFFSET = 0.5

local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

-- Tile coordinates crossing this boundary are finite integers: a fractional
-- index would otherwise flow into the permission grid's shifted record read.
local function requireIndex(value, name, context)
  if not finiteInteger(value) then
    Errors.raise(
      FieldErrors.FIELD_COORDINATES_INVALID,
      name .. " must be a finite integer tile coordinate, got " .. tostring(value),
      context
    )
  end
end

-- Heights are continuous (fractional is legitimate); only non-finite values
-- are rejected, mirroring GameSave's height validation.
local function requireFinite(value, name, context)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    Errors.raise(FieldErrors.FIELD_COORDINATES_INVALID, name .. " must be finite, got " .. tostring(value), context)
  end
end

local function origin(runtimeMap)
  assert(runtimeMap and runtimeMap.coordinateOrigin, "runtime map coordinate origin required")
  return runtimeMap.coordinateOrigin.x, runtimeMap.coordinateOrigin.z
end

local function requireLocal(runtimeMap, localX, localZ, context)
  assert(runtimeMap.collision and runtimeMap.collision.containsLocal, "runtime map collision coverage required")
  if not runtimeMap.collision:containsLocal(localX, localZ) then
    context = context or {}
    context.localX, context.localZ = localX, localZ
    context.mapId = runtimeMap.mapId
    Errors.raise(
      FieldErrors.FIELD_COORDINATES_OUT_OF_COVERAGE,
      string.format(
        "coordinate (%s,%s) is outside map %s permission coverage",
        tostring(localX),
        tostring(localZ),
        tostring(runtimeMap.mapId)
      ),
      context
    )
  end
end

function FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  assert(type(fieldX) == "number" and type(fieldZ) == "number", "field coordinates must be numbers")
  requireIndex(fieldX, "fieldX", { fieldX = fieldX, fieldZ = fieldZ })
  requireIndex(fieldZ, "fieldZ", { fieldX = fieldX, fieldZ = fieldZ })
  local originX, originZ = origin(runtimeMap)
  local localX, localZ = fieldX - originX, fieldZ - originZ
  requireLocal(runtimeMap, localX, localZ, { fieldX = fieldX, fieldZ = fieldZ })
  return localX, localZ
end

function FieldCoordinates.localToField(runtimeMap, localX, localZ)
  assert(type(localX) == "number" and type(localZ) == "number", "local coordinates must be numbers")
  requireIndex(localX, "localX", { localX = localX, localZ = localZ })
  requireIndex(localZ, "localZ", { localX = localX, localZ = localZ })
  requireLocal(runtimeMap, localX, localZ)
  local originX, originZ = origin(runtimeMap)
  return localX + originX, localZ + originZ
end

function FieldCoordinates.fieldToWorld(runtimeMap, fieldX, fieldZ, worldY)
  assert(type(worldY) == "number", "world Y must be a number")
  requireFinite(worldY, "worldY", { worldY = worldY })
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local worldX, worldZ = FieldGrid.tileCenterToWorld(localX, localZ)
  return { x = worldX, y = worldY, z = worldZ }
end

return FieldCoordinates
