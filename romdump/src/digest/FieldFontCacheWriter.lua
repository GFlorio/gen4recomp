-- Atomic marker-last writer for the field-font derived class. Writes the
-- provenance record, the font definition Lua, and the atlas PNG, readback-
-- validates both, and only then publishes the completion marker. On any
-- failure the whole class is invalidated so a partial build never reads as
-- complete.

local Errors = require("libs.rom.src.Errors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")

local FieldFontCacheWriter = {}

function FieldFontCacheWriter.isReady(cacheFs, fontId, marker)
  return FieldFontCache.isReady(cacheFs, fontId, marker)
end

function FieldFontCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.font and bundle.atlas, "write requires a font bundle")
  assert(bundle.font.schema == FieldFontCache.SCHEMA, "font def schema mismatch")
  local ok, err = pcall(function()
    cacheFs:remove(FieldFontCache.markerPath())
    cacheFs:writeLua(FieldFontCache.provenancePath(), {
      schema = "g4-field-font-provenance-v1",
      dependencies = bundle.dependencies,
    })
    cacheFs:write(FieldFontCache.atlasPath(bundle.fontId), bundle.atlas)
    cacheFs:writeLua(FieldFontCache.defPath(bundle.fontId), bundle.font)
    local def = cacheFs:loadLua(FieldFontCache.defPath(bundle.fontId))
    if type(def) ~= "table" or def.schema ~= FieldFontCache.SCHEMA or def.fontId ~= bundle.fontId then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font def readback failed", { fontId = bundle.fontId })
    end
    if not cacheFs:exists(FieldFontCache.atlasPath(bundle.fontId), "file") then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font atlas readback failed", { fontId = bundle.fontId })
    end
    cacheFs:write(FieldFontCache.markerPath(), bundle.marker)
  end)
  if ok then
    return true
  end
  pcall(function()
    FieldFontCache.invalidate(cacheFs)
  end)
  error(err)
end

return FieldFontCacheWriter
