-- Persists one normalized field-map record and its dependencies, validating
-- readback before writing the completion marker last.

local Errors = require("libs.rom.src.Errors")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")

local FieldMapDataCacheWriter = {}

local function persist(cacheFs, bundle)
  local mapId = bundle.mapId
  cacheFs:remove(FieldMapDataCache.markerPath(mapId))
  cacheFs:writeLua(FieldMapDataCache.fieldPath(mapId), bundle.field)
  cacheFs:writeLua(FieldMapDataCache.dependenciesPath(mapId), bundle.dependencies)

  local field, fieldErr = cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId))
  local dependencies, dependenciesErr = cacheFs:loadLua(FieldMapDataCache.dependenciesPath(mapId))
  if not field or not dependencies then
    Errors.raise(
      "FIELD_MAP_DATA_CACHE_STALE",
      "field-map artifacts failed readback: " .. Errors.format(fieldErr or dependenciesErr),
      { mapId = mapId }
    )
  end
  if field.schema ~= "g4-field-map-v1" or field.mapId ~= mapId then
    Errors.raise(
      "FIELD_MAP_DATA_CACHE_STALE",
      "field-map readback has the wrong identity",
      { mapId = mapId, schema = field.schema, actualMapId = field.mapId }
    )
  end
  cacheFs:write(FieldMapDataCache.markerPath(mapId), bundle.marker)
  return bundle.marker
end

function FieldMapDataCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid field-map bundle")
  local ok, result = pcall(persist, cacheFs, bundle)
  if ok then
    return result
  end
  pcall(function()
    FieldMapDataCache.invalidateMap(cacheFs, bundle.mapId)
  end)
  error(result)
end

return FieldMapDataCacheWriter
