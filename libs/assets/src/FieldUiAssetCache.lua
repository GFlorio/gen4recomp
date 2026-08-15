-- Readiness, paths, and strict validation for the generated HGSS field-UI
-- class: one manifest (`ui.lua`) carrying the semantic surfaces and the
-- strict metadata sections, binary assets (PNG atlases) under the UI asset
-- root, and a completion marker written last with the ROM SHA-1 and producer
-- dependency hash. The manifest is the single mod-facing contract for
-- dialogue frames, signposts, the Start Menu, and the Trainer Card; it never
-- carries NARC/member ids. A UI class is ready only when the marker matches
-- exactly and every indexed file exists. Paths are cache-relative; all IO
-- goes through a CacheFs.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

local FieldUiAssetCache = {}

FieldUiAssetCache.FORMAT = Contract.fieldUi.cacheFormat
FieldUiAssetCache.SCHEMA = Contract.fieldUi.schema

local DATA_DIR = "data/generated/field/ui"
local ASSET_DIR = "assets/generated/field/ui"

function FieldUiAssetCache.dir()
  return DATA_DIR
end
function FieldUiAssetCache.assetDir()
  return ASSET_DIR
end
function FieldUiAssetCache.manifestPath()
  return DATA_DIR .. "/ui.lua"
end
function FieldUiAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function FieldUiAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldUiAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldUiAssetCache.FORMAT, romSha1, depHash)
end

-- Strict manifest validation: required arrays, strict enums, and every
-- rectangle/size/index finite, integral, non-negative, and inside its
-- atlas. Returns nil, err on the first violation.

---@param manifest table
---@return boolean, Errors.Error?
function FieldUiAssetCache.validateManifest(manifest)
  if type(manifest) ~= "table" then
    return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "manifest is not a table", {})
  end
  if manifest.schema ~= FieldUiAssetCache.SCHEMA then
    return false,
      Errors.new("FIELD_UI_MANIFEST_INVALID", "manifest schema mismatch", {
        schema = manifest.schema,
        expected = FieldUiAssetCache.SCHEMA,
      })
  end
  if type(manifest.reference) ~= "table" or manifest.reference.width ~= 256 or manifest.reference.height ~= 192 then
    return false,
      Errors.new("FIELD_UI_MANIFEST_INVALID", "manifest reference must be the 256x192 field screen", {
        reference = manifest.reference,
      })
  end
  if type(manifest.assets) ~= "table" or next(manifest.assets) == nil then
    return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "manifest assets must be a non-empty table", {})
  end
  local atlasSizes = {}
  for key, entry in pairs(manifest.assets) do
    if type(key) ~= "string" or key == "" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "asset key must be a non-empty string", {})
    end
    if type(entry) ~= "table" or type(entry.image) ~= "string" or entry.image == "" then
      return false,
        Errors.new("FIELD_UI_MANIFEST_INVALID", "asset " .. key .. " must name an image path", { key = key })
    end
    local function sizeField(field)
      local v = entry[field]
      return type(v) == "number" and v % 1 == 0 and v >= 1
    end
    if not sizeField("width") or not sizeField("height") then
      return false,
        Errors.new("FIELD_UI_MANIFEST_INVALID", "asset " .. key .. " needs positive integral dimensions", {
          key = key,
        })
    end
    if atlasSizes[key] then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "duplicate asset key " .. key, { key = key })
    end
    atlasSizes[key] = { width = entry.width, height = entry.height }
  end

  local function rectInAtlas(rect, atlasKey, what)
    if type(rect) ~= "table" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", what .. " must be a rectangle", { what = what })
    end
    for _, field in ipairs({ "x", "y", "width", "height" }) do
      local v = rect[field]
      if type(v) ~= "number" or v % 1 ~= 0 or v < 0 then
        return false,
          Errors.new("FIELD_UI_MANIFEST_INVALID", what .. " " .. field .. " must be a non-negative integer", {
            what = what,
            field = field,
          })
      end
    end
    if rect.width == 0 or rect.height == 0 then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", what .. " must be non-empty", { what = what })
    end
    local atlas = atlasSizes[atlasKey]
    if not atlas or rect.x + rect.width > atlas.width or rect.y + rect.height > atlas.height then
      return false,
        Errors.new("FIELD_UI_MANIFEST_INVALID", what .. " escapes its atlas " .. atlasKey, {
          what = what,
          atlas = atlasKey,
        })
    end
    return true
  end

  local function section(name, checker)
    if type(manifest[name]) ~= "table" then
      return false,
        Errors.new("FIELD_UI_MANIFEST_INVALID", "manifest section " .. name .. " must be a table", {
          section = name,
        })
    end
    return checker(manifest[name])
  end

  local ok, err = section("dialogueFrames", function(s)
    if type(s.count) ~= "number" or s.count % 1 ~= 0 or s.count < 1 then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "dialogueFrames.count must be a positive integer", {})
    end
    if type(s.frameTiles) ~= "table" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "dialogueFrames.frameTiles must be a table", {})
    end
    for frame = 0, s.count - 1 do
      local ok, err = rectInAtlas(s.frameTiles[frame], "hgss.dialogue_frame.tiles", "frame " .. frame .. " tiles")
      if not ok then
        return false, err
      end
    end
    if type(s.palettes) ~= "table" or s.palettes[0] == nil or s.palettes[s.count - 1] == nil then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "dialogueFrames.palettes must cover every frame", {})
    end
    return true
  end)
  if not ok then
    return false, err
  end

  local ok, err = section("signposts", function(s)
    if type(s.frame) ~= "table" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "signposts.frame must be a table", {})
    end
    local ok, err = rectInAtlas(s.frame.tiles, "hgss.signpost.tiles", "signpost frame tiles")
    if not ok then
      return false, err
    end
    if type(s.types) ~= "table" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "signposts.types must be a table", {})
    end
    for _, typeEntry in pairs(s.types) do
      if type(typeEntry) ~= "table" or type(typeEntry.sourceType) ~= "number" or typeEntry.sourceType % 1 ~= 0 then
        return false,
          Errors.new("FIELD_UI_MANIFEST_INVALID", "signpost type entries must carry an integral sourceType", {})
      end
      if typeEntry.wayfinding ~= nil then
        local ok, err = rectInAtlas(typeEntry.wayfinding, "hgss.signpost.wayfinding", "signpost wayfinding")
        if not ok then
          return false, err
        end
      end
    end
    return true
  end)
  if not ok then
    return false, err
  end

  local ok, err = section("startMenu", function(s)
    local ok, err = rectInAtlas(s.background, "hgss.start_menu.background", "start menu background")
    if not ok then
      return false, err
    end
    if type(s.cursor) ~= "table" or type(s.cursor.frames) ~= "table" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "startMenu.cursor must carry frames", {})
    end
    for _, frameEntry in ipairs(s.cursor.frames) do
      local ok, err = rectInAtlas(frameEntry, "hgss.start_menu.cursor", "start menu cursor frame")
      if not ok then
        return false, err
      end
      if type(frameEntry.duration) ~= "number" or frameEntry.duration % 1 ~= 0 or frameEntry.duration < 1 then
        return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "cursor frame duration must be a positive integer", {})
      end
    end
    if type(s.slots) ~= "table" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "startMenu.slots must be a table", {})
    end
    for id, slot in pairs(s.slots) do
      local ok, err = rectInAtlas(slot, "hgss.start_menu.background", "start menu slot " .. tostring(id))
      if not ok then
        return false, err
      end
    end
    if type(s.icons) ~= "table" then
      return false, Errors.new("FIELD_UI_MANIFEST_INVALID", "startMenu.icons must be a table", {})
    end
    return true
  end)
  if not ok then
    return false, err
  end

  local ok, err = section("trainerCard", function(s)
    local ok, err = rectInAtlas(s.front, "hgss.trainer_card.front", "trainer card front")
    if not ok then
      return false, err
    end
    return true
  end)
  if not ok then
    return false, err
  end

  return true
end

-- Every generated file the manifest indexes must exist for the class to be
-- ready. The marker must also match exactly; the manifest itself must be
-- present and valid.
function FieldUiAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldUiAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if type(manifest) ~= "table" then
    return false
  end
  local ok = FieldUiAssetCache.validateManifest(manifest)
  if not ok then
    return false
  end
  for _, entry in pairs(manifest.assets) do
    if not cacheFs:exists(entry.image, "file") then
      return false
    end
  end
  return true
end

return FieldUiAssetCache
