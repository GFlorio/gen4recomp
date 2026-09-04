-- Persists a compiled field-weather bundle through the shared staged
-- publication primitive: the catalog and its provenance are written into a
-- disposable staging root, read back and validated there, and only then is
-- the completed stage published with the marker last.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")

local FieldWeatherCacheWriter = {}

function FieldWeatherCacheWriter.isReady(cacheFs, marker)
  return FieldWeatherCache.isReady(cacheFs, marker)
end

local function stageBundle(tx, bundle)
  local stage = tx.stage
  stage:writeLua(FieldWeatherCache.provenancePath(), bundle.provenance)
  stage:writeLua(FieldWeatherCache.catalogPath(), bundle.catalog)
  local catalog = stage:loadLua(FieldWeatherCache.catalogPath())
  if type(catalog) ~= "table" then
    Errors.raise("FIELD_WEATHER_CACHE_READBACK_FAILED", "weather catalog readback failed", {})
  end
  local typedCatalog = catalog --[[@as FieldWeatherCache.Catalog]]
  local ok, err = FieldWeatherCache.validateCatalog(typedCatalog)
  if not ok then
    Errors.raise("FIELD_WEATHER_CACHE_READBACK_FAILED", "weather catalog readback is invalid", {
      cause = err and err.message or tostring(err),
    })
  end
  stage:write(FieldWeatherCache.markerPath(), bundle.marker)
end

function FieldWeatherCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.catalog and bundle.provenance, "write requires a weather bundle")
  assert(bundle.catalog.schema == FieldWeatherCache.SCHEMA, "weather catalog schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "field-weather", {
    FieldWeatherCache.dir(),
  })
  local ok, err = pcall(stageBundle, tx, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return FieldWeatherCacheWriter
