-- Persists one normalized field-map record through the shared staged
-- publication primitive: the record and its dependencies are written into a
-- disposable staging root, readback-validated there, and only then is the
-- completed stage published with the marker last. Staging and validation are
-- one step; publication happens outside that step's error handler, so a
-- publish failure never triggers writer-level stage cleanup that could delete
-- the last remaining copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

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
  return bundle.marker
end

function FieldMapDataCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid field-map bundle")
  local tx =
    ArtifactPublisher.begin(cacheFs, "field-map-data-" .. bundle.mapId, { FieldMapDataCache.mapDir(bundle.mapId) })
  local ok, result = pcall(persist, tx, bundle)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return FieldMapDataCacheWriter
