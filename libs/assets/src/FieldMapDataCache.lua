-- Defines paths and readiness for lightweight generated field map records.
-- Event changes stay independent from heavy map geometry caches.

local FieldMapDataCache = {}

local Validate = require("libs.assets.src.Validate")

FieldMapDataCache.FORMAT = "g4-field-map-cache-v1"
FieldMapDataCache.FIELD_SCHEMA = "g4-field-map-v1"

-- The event collections the current field-map schema always carries.
local EVENT_COLLECTIONS = { "background", "objects", "warps", "coordinates" }

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

-- True only if the marker is exact, the record carries the current identity
-- (schema and mapId), dependencies load, and every required event collection
-- is present as an array.
function FieldMapDataCache.isReady(cacheFs, mapId, expectedMarker)
  if cacheFs:read(FieldMapDataCache.markerPath(mapId)) ~= expectedMarker then
    return false
  end
  local field = cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId))
  local dependencies = cacheFs:loadLua(FieldMapDataCache.dependenciesPath(mapId))
  if
    type(field) ~= "table"
    or field.schema ~= FieldMapDataCache.FIELD_SCHEMA
    or field.mapId ~= mapId
    or type(dependencies) ~= "table"
  then
    return false
  end
  local events = field.events
  if type(events) ~= "table" then
    return false
  end
  for _, key in ipairs(EVENT_COLLECTIONS) do
    if not Validate.isArray(events[key]) then
      return false
    end
  end
  return true
end

return FieldMapDataCache
