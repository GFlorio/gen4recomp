-- Persists one normalized field-map record through the shared staged
-- publication primitive: the record and its dependencies are written into a
-- disposable staging root, readback-validated there, and only then is the
-- completed stage published with the marker last. On any failure the stage is
-- discarded and any previous live record for that map is left untouched.

local Errors = require("libs.rom.src.Errors")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local ArtifactPublisher = require("libs.rom.src.ArtifactPublisher")

local FieldMapDataCacheWriter = {}

local function persist(tx, bundle)
  local mapId = bundle.mapId
  local stage = tx.stage
  stage:writeLua(FieldMapDataCache.fieldPath(mapId), bundle.field)
  stage:writeLua(FieldMapDataCache.dependenciesPath(mapId), bundle.dependencies)

  local field, fieldErr = stage:loadLua(FieldMapDataCache.fieldPath(mapId))
  local dependencies, dependenciesErr = stage:loadLua(FieldMapDataCache.dependenciesPath(mapId))
  if not field or not dependencies then
    Errors.raise(
      "FIELD_MAP_DATA_CACHE_STALE",
      "field-map artifacts failed readback: " .. Errors.format(fieldErr or dependenciesErr),
      { mapId = mapId }
    )
  end
  if field.schema ~= FieldMapDataCache.FIELD_SCHEMA or field.mapId ~= mapId then
    Errors.raise(
      "FIELD_MAP_DATA_CACHE_STALE",
      "field-map readback has the wrong identity",
      { mapId = mapId, schema = field.schema, actualMapId = field.mapId }
    )
  end
  stage:write(FieldMapDataCache.markerPath(mapId), bundle.marker)
  tx:publish()
  return bundle.marker
end

function FieldMapDataCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid field-map bundle")
  local tx =
    ArtifactPublisher.begin(cacheFs, "field-map-data-" .. bundle.mapId, { FieldMapDataCache.mapDir(bundle.mapId) })
  local ok, result = pcall(persist, tx, bundle)
  if ok then
    return result
  end
  tx:abort()
  error(result)
end

return FieldMapDataCacheWriter
