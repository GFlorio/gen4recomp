-- Readiness and paths for the derived field-font cache. The field font is one
-- of the independently rebuildable derived classes (map geometry, actor
-- visuals, messages/font): changing the font compiler must not disturb the raw
-- ROM dump, compiled maps, or message banks. A font is ready only when the
-- completion marker matches exactly and the definition, the glyph atlas, and
-- the focus-indicator PNG are present. Paths are cache-relative; all IO goes
-- through a CacheFs (PNG binaries live under the derived assets root).

local FieldFontCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")

FieldFontCache.FORMAT = Contract.font.cacheFormat
FieldFontCache.SCHEMA = Contract.font.schema

-- The source focus-indicator frames are 24x32 (the text printer's YESNO
-- screen-focus graphic); the compiled definition's frame rects must match.
FieldFontCache.FOCUS_FRAME_WIDTH = 24
FieldFontCache.FOCUS_FRAME_HEIGHT = 32

local DATA_DIR = "data/generated/field/font"
local ASSET_DIR = "assets/generated/field/font"

function FieldFontCache.dir()
  return DATA_DIR
end
function FieldFontCache.assetDir()
  return ASSET_DIR
end
function FieldFontCache.defPath(fontId)
  return string.format("%s/font-%d.lua", DATA_DIR, fontId)
end
function FieldFontCache.atlasPath(fontId)
  return string.format("%s/font-%d.png", ASSET_DIR, fontId)
end

function FieldFontCache.focusIndicatorsPath(fontId)
  return string.format("%s/font-%d-focus-indicators.png", ASSET_DIR, fontId)
end
function FieldFontCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function FieldFontCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldFontCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldFontCache.FORMAT, romSha1, depHash)
end

function FieldFontCache.isReady(cacheFs, fontId, expectedMarker)
  if cacheFs:read(FieldFontCache.markerPath()) ~= expectedMarker then
    return false
  end
  if not cacheFs:exists(FieldFontCache.defPath(fontId), "file") then
    return false
  end
  if not cacheFs:exists(FieldFontCache.atlasPath(fontId), "file") then
    return false
  end
  if not cacheFs:exists(FieldFontCache.focusIndicatorsPath(fontId), "file") then
    return false
  end
  return true
end

return FieldFontCache
