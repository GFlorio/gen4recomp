-- Persists a compiled field-font bundle through the shared staged
-- publication primitive: the provenance record, the font definition Lua, and
-- the two generated PNGs (glyph atlas and focus indicators) are written into a
-- disposable staging root, readback-validated there, and only then is the
-- completed stage published with the marker last. Staging and validation are
-- one step; publication happens outside that step's error handler, so a
-- publish failure never triggers writer-level stage cleanup that could delete
-- the last remaining copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldFontCacheWriter = {}

function FieldFontCacheWriter.isReady(cacheFs, fontId, marker)
  return FieldFontCache.isReady(cacheFs, fontId, marker)
end

local function stageBundle(tx, bundle)
  local stage = tx.stage
  stage:writeLua(FieldFontCache.provenancePath(), {
    schema = "g4-field-font-provenance-v1",
    dependencies = bundle.dependencies,
  })
  stage:write(FieldFontCache.atlasPath(bundle.fontId), bundle.atlas)
  stage:write(FieldFontCache.focusIndicatorsPath(bundle.fontId), bundle.focusIndicators)
  stage:writeLua(FieldFontCache.defPath(bundle.fontId), bundle.font)
  local def = stage:loadLua(FieldFontCache.defPath(bundle.fontId))
  if type(def) ~= "table" or def.schema ~= FieldFontCache.SCHEMA or def.fontId ~= bundle.fontId then
    Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font def readback failed", { fontId = bundle.fontId })
  end
  if not stage:exists(FieldFontCache.atlasPath(bundle.fontId), "file") then
    Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font atlas readback failed", { fontId = bundle.fontId })
  end
  if not stage:exists(FieldFontCache.focusIndicatorsPath(bundle.fontId), "file") then
    Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font focus-indicator readback failed", { fontId = bundle.fontId })
  end
  stage:write(FieldFontCache.markerPath(), bundle.marker)
end

function FieldFontCacheWriter.write(cacheFs, bundle)
  assert(
    bundle and bundle.marker and bundle.font and bundle.atlas and bundle.focusIndicators,
    "write requires a font bundle"
  )
  assert(bundle.font.schema == FieldFontCache.SCHEMA, "font def schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "field-font", {
    FieldFontCache.assetDir(),
    FieldFontCache.dir(),
  })
  local ok, err = pcall(stageBundle, tx, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return FieldFontCacheWriter
