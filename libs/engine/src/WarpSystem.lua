-- Resolves normalized field warp records into destination map coordinates and
-- terrain surfaces. Warp indexes are zero-based; event coordinates remain in
-- the authoritative global field domain.

local Errors = require("libs.rom.src.Errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

local WarpSystem = {}

local WARP_Y_SCALE = 16
local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 }, south = { x = 0, z = 1 },
  west = { x = -1, z = 0 }, east = { x = 1, z = 0 },
}

local function warps(runtimeMap)
  return assert(runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.events
    and runtimeMap.fieldData.events.warps, "runtime map warp data required")
end

function WarpSystem.findAt(runtimeMap, fieldX, fieldZ)
  for _, warp in ipairs(warps(runtimeMap)) do
    if warp.x == fieldX and warp.z == fieldZ then return warp end
  end
  return nil
end

function WarpSystem.findBlockedFacing(runtimeMap, fieldX, fieldZ, direction)
  local delta = DIRECTION_DELTAS[direction]
  if not delta then return nil end
  local destinationX, destinationZ = fieldX + delta.x, fieldZ + delta.z
  local warp = WarpSystem.findAt(runtimeMap, destinationX, destinationZ)
  if not warp then return nil end
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, destinationX, destinationZ)
  if runtimeMap.permissions:isBlockedLocal(localX, localZ) then return warp end
  return nil
end

local function loadDestination(loader, sourceMap, warp)
  local ok, result = pcall(loader.load, loader, warp.destinationMapId)
  if ok then return result end
  if Errors.is(result) and (result.code == "FIELD_MAP_UNKNOWN"
    or result.code == "FIELD_DESTINATION_MAP_UNKNOWN") then
    Errors.raise("FIELD_DESTINATION_MAP_UNKNOWN", "warp destination map is unavailable", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      cause = result.code,
    })
  end
  error(result)
end

function WarpSystem.resolveDestination(loader, sourceMap, warp)
  assert(loader and loader.load, "warp destination loader required")
  assert(sourceMap and sourceMap.mapId and warp, "source map and warp required")
  if warp.destinationWarpId == 0x100 then
    Errors.raise("FIELD_DYNAMIC_WARP_UNSUPPORTED", "dynamic warp anchors are not supported", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      destinationWarpId = warp.destinationWarpId,
    })
  end

  local destinationMap = loadDestination(loader, sourceMap, warp)
  local destinationWarp = warps(destinationMap)[warp.destinationWarpId + 1]
  if not destinationWarp or destinationWarp.index ~= warp.destinationWarpId then
    Errors.raise("FIELD_DESTINATION_WARP_UNKNOWN", "destination warp index is unavailable", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = destinationMap.mapId,
      destinationWarpId = warp.destinationWarpId,
    })
  end

  local localX, localZ = FieldCoordinates.fieldToLocal(
    destinationMap, destinationWarp.x, destinationWarp.z)
  local hintY = destinationWarp.y / WARP_Y_SCALE
  local sample = SurfaceResolver.new(destinationMap.terrain):resolve({
    localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = hintY,
  })
  return {
    sourceMap = sourceMap,
    sourceWarp = warp,
    destinationMap = destinationMap,
    destinationWarp = destinationWarp,
    fieldX = destinationWarp.x,
    fieldZ = destinationWarp.z,
    warpYHint = hintY,
    surfaceId = sample.surfaceId,
    worldY = sample.worldY,
    suppression = {
      mapId = destinationMap.mapId,
      fieldX = destinationWarp.x,
      fieldZ = destinationWarp.z,
    },
  }
end

function WarpSystem.isSuppressed(token, mapId, fieldX, fieldZ)
  return token ~= nil and token.mapId == mapId
    and token.fieldX == fieldX and token.fieldZ == fieldZ
end

function WarpSystem.updateSuppression(token, mapId, fieldX, fieldZ)
  if WarpSystem.isSuppressed(token, mapId, fieldX, fieldZ) then return token end
  return nil
end

return WarpSystem
