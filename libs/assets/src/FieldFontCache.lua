-- Readiness, paths, and invalidation for the derived field-font cache. The
-- field font is one of the independently rebuildable derived classes (map
-- geometry, actor visuals, messages/font): changing the font compiler must not
-- disturb the raw ROM dump, compiled maps, or message banks. A font is ready
-- only when the completion marker matches exactly and both the definition and
-- the atlas PNG are present. Paths are cache-relative; all IO goes through a
-- CacheFs (PNG binaries live under the derived assets root).

local FieldFontCache = {}

FieldFontCache.FORMAT = "field-font-cache-v1"
FieldFontCache.SCHEMA = "g4-field-font-v1"

local DATA_DIR = "data/generated/field/font"
local ASSET_DIR = "assets/generated/field/font"

function FieldFontCache.dir() return DATA_DIR end
function FieldFontCache.defPath(fontId)
  return string.format("%s/font-%d.lua", DATA_DIR, fontId)
end
function FieldFontCache.atlasPath(fontId)
  return string.format("%s/font-%d.png", ASSET_DIR, fontId)
end
function FieldFontCache.provenancePath() return DATA_DIR .. "/provenance.lua" end
function FieldFontCache.markerPath() return DATA_DIR .. "/complete" end

function FieldFontCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldFontCache.FORMAT, romSha1, depHash)
end

function FieldFontCache.isReady(cacheFs, fontId, expectedMarker)
  if cacheFs:read(FieldFontCache.markerPath()) ~= expectedMarker then return false end
  if not cacheFs:exists(FieldFontCache.defPath(fontId), "file") then return false end
  if not cacheFs:exists(FieldFontCache.atlasPath(fontId), "file") then return false end
  return true
end

function FieldFontCache.invalidate(cacheFs)
  for _, root in ipairs({ DATA_DIR, ASSET_DIR }) do
    assert(root:find("generated", 1, true), "derived root must live under a generated subtree")
    cacheFs:removeTree(root)
  end
  return true
end

return FieldFontCache
