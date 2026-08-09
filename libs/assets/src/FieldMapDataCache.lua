-- Defines paths, readiness, and invalidation for lightweight generated field
-- map records. Event changes stay independent from heavy map geometry caches.

local FieldMapDataCache = {}

FieldMapDataCache.FORMAT = "g4-field-map-cache-v1"

function FieldMapDataCache.mapDir(mapId)
  assert(type(mapId) == "number" and mapId >= 0, "mapId must be non-negative")
  return string.format("data/generated/field/maps/%04d", mapId)
end

function FieldMapDataCache.fieldPath(mapId)
  return FieldMapDataCache.mapDir(mapId) .. "/field.lua"
end

function FieldMapDataCache.dependenciesPath(mapId)
  return FieldMapDataCache.mapDir(mapId) .. "/dependencies.lua"
end

function FieldMapDataCache.markerPath(mapId)
  return FieldMapDataCache.mapDir(mapId) .. "/complete"
end

function FieldMapDataCache.marker(romSha1, mapId, dependencyHash)
  return string.format("%s:%s:%d:%s", FieldMapDataCache.FORMAT, romSha1, mapId, dependencyHash)
end

function FieldMapDataCache.isReady(cacheFs, mapId, expectedMarker)
  if cacheFs:read(FieldMapDataCache.markerPath(mapId)) ~= expectedMarker then
    return false
  end
  local field = cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId))
  local dependencies = cacheFs:loadLua(FieldMapDataCache.dependenciesPath(mapId))
  return type(field) == "table"
    and field.schema == "g4-field-map-v1"
    and field.mapId == mapId
    and type(dependencies) == "table"
end

function FieldMapDataCache.invalidateMap(cacheFs, mapId)
  cacheFs:removeTree(FieldMapDataCache.mapDir(mapId))
end

return FieldMapDataCache
