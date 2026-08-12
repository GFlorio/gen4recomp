-- Persists a compiled field-font bundle through the shared staged
-- publication primitive: the provenance record, the font definition Lua, and
-- the atlas PNG are written into a disposable staging root, readback-validated
-- there, and only then is the completed stage published with the marker last.
-- On any failure the stage is discarded and the previous live font artifact is
-- left untouched, so a partial build never reads as complete and never destroys
-- a valid one.

local Errors = require("libs.errors.src.Errors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldFontCacheWriter = {}

function FieldFontCacheWriter.isReady(cacheFs, fontId, marker)
  return FieldFontCache.isReady(cacheFs, fontId, marker)
end

function FieldFontCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.font and bundle.atlas, "write requires a font bundle")
  assert(bundle.font.schema == FieldFontCache.SCHEMA, "font def schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "field-font", {
    FieldFontCache.assetDir(),
    FieldFontCache.dir(),
  })
  local ok, err = pcall(function()
    local stage = tx.stage
    stage:writeLua(FieldFontCache.provenancePath(), {
      schema = "g4-field-font-provenance-v1",
      dependencies = bundle.dependencies,
    })
    stage:write(FieldFontCache.atlasPath(bundle.fontId), bundle.atlas)
    stage:writeLua(FieldFontCache.defPath(bundle.fontId), bundle.font)
    local def = stage:loadLua(FieldFontCache.defPath(bundle.fontId))
    if type(def) ~= "table" or def.schema ~= FieldFontCache.SCHEMA or def.fontId ~= bundle.fontId then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font def readback failed", { fontId = bundle.fontId })
    end
    if not stage:exists(FieldFontCache.atlasPath(bundle.fontId), "file") then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font atlas readback failed", { fontId = bundle.fontId })
    end
    stage:write(FieldFontCache.markerPath(), bundle.marker)
    tx:publish()
  end)
  if ok then
    return true
  end
  tx:abort()
  error(err)
end

return FieldFontCacheWriter
