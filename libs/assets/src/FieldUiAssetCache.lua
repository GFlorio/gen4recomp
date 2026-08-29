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

---@class FieldUiAssetCache.Rect
---@field x integer
---@field y integer
---@field width integer
---@field height integer

---@class FieldUiAssetCache.Asset
---@field image string
---@field width integer
---@field height integer

---@class FieldUiAssetCache.Manifest
---@field schema string
---@field reference FieldUiAssetCache.Rect
---@field assets table<string, FieldUiAssetCache.Asset>
---@field [string] table

FieldUiAssetCache.FORMAT = Contract.fieldUi.cacheFormat
FieldUiAssetCache.SCHEMA = Contract.fieldUi.schema

-- The audited HGSS field-UI geometry is a generated-class invariant,
-- not a tunable: dialogue and signpost frame members carry 18 tiles (a
-- 144x8 strip) and every wayfinding member carries 24 tiles but is
-- persisted as a precomposed 48x32 final surface (6 columns x 4 rows).
-- The producer arranges the raw 24 tiles into that surface at build time;
-- runtime draws a single rect. The validator enforces the final 48x32
-- shape. The producer and validator consume these numbers from this one
-- protocol owner.
FieldUiAssetCache.GEOMETRY = {
  FRAME_TILES = 18,
  WAYFINDING_TILES = 24,
  WAYFINDING_COLUMNS = 6,
  WAYFINDING_ROWS = 4,
  WAYFINDING_WIDTH = 48,
  WAYFINDING_HEIGHT = 32,
}

-- The generated field-UI asset protocol ids: one constant table so the
-- producer, the cache validation, and the renderers never repeat the raw
-- strings.
FieldUiAssetCache.ASSET = {
  DIALOGUE_FRAME_TILES = "hgss.dialogue_frame.tiles",
  DIALOGUE_CONTINUE_CURSOR = "hgss.dialogue_continue_cursor",
  SIGNPOST_TILES = "hgss.signpost.tiles",
  SIGNPOST_WAYFINDING = "hgss.signpost.wayfinding",
  START_MENU_BACKGROUND = "hgss.start_menu.background",
  START_MENU_CURSOR = "hgss.start_menu.cursor",
  TRAINER_CARD_FRONT = "hgss.trainer_card.front",
}

-- One error code for every malformed generated class: the manifest is the
-- single strict structural boundary, so all violations share the code while
-- the message names the exact broken field.
local MANIFEST_INVALID = "FIELD_UI_MANIFEST_INVALID"

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

---@class FieldUiAssetCache.ValidationContext
---@field manifest FieldUiAssetCache.Manifest
---@field atlasSizes table<string, { width: integer, height: integer }>

---@param entry table
---@param field string
---@return boolean
local function validAssetSize(entry, field)
  local value = entry[field] ---@type number
  return type(value) == "number" and value % 1 == 0 and value >= 1
end

---@param key unknown
---@param entry unknown
---@return boolean, Errors.Error?
local function validateAssetEntry(key, entry)
  if type(key) ~= "string" or key == "" then
    return false, Errors.new(MANIFEST_INVALID, "asset key must be a non-empty string", {})
  end
  if type(entry) ~= "table" or type(entry.image) ~= "string" or entry.image == "" then
    return false, Errors.new(MANIFEST_INVALID, "asset " .. key .. " must name an image path", { key = key })
  end
  if not validAssetSize(entry, "width") or not validAssetSize(entry, "height") then
    return false,
      Errors.new(MANIFEST_INVALID, "asset " .. key .. " needs positive integral dimensions", {
        key = key,
      })
  end
  return true
end

---@param manifest FieldUiAssetCache.Manifest
---@return boolean, FieldUiAssetCache.ValidationContext|Errors.Error
local function validateAssets(manifest)
  if type(manifest.assets) ~= "table" or next(manifest.assets) == nil then
    return false, Errors.new(MANIFEST_INVALID, "manifest assets must be a non-empty table", {})
  end
  local context = {
    manifest = manifest,
    atlasSizes = {},
  } ---@type FieldUiAssetCache.ValidationContext
  for key, entry in pairs(manifest.assets) do
    local valid, err = validateAssetEntry(key, entry)
    if not valid then
      return false, assert(err)
    end
    local asset = entry ---@type FieldUiAssetCache.Asset
    context.atlasSizes[key] = { width = asset.width, height = asset.height }
  end
  return true, context
end

---@param context FieldUiAssetCache.ValidationContext
---@param rect table
---@param atlasKey string
---@param what string
---@return boolean, Errors.Error?
local function rectInAtlas(context, rect, atlasKey, what)
  if type(rect) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, what .. " must be a rectangle", { what = what })
  end
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    local value = rect[field] ---@type number
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
      return false,
        Errors.new(MANIFEST_INVALID, what .. " " .. field .. " must be a non-negative integer", {
          what = what,
          field = field,
        })
    end
  end
  if rect.width == 0 or rect.height == 0 then
    return false, Errors.new(MANIFEST_INVALID, what .. " must be non-empty", { what = what })
  end
  local atlas = context.atlasSizes[atlasKey]
  if not atlas or rect.x + rect.width > atlas.width or rect.y + rect.height > atlas.height then
    return false,
      Errors.new(MANIFEST_INVALID, what .. " escapes its atlas " .. atlasKey, {
        what = what,
        atlas = atlasKey,
      })
  end
  return true
end

-- A rect must be an exact HGSS strip (`width` x 8) inside its atlas.
---@param context FieldUiAssetCache.ValidationContext
---@param rect table
---@param atlasKey string
---@param what string
---@param width integer
---@return boolean, Errors.Error?
local function stripInAtlas(context, rect, atlasKey, what, width)
  local ok, err = rectInAtlas(context, rect, atlasKey, what)
  if not ok then
    return false, err
  end
  if rect.width ~= width or rect.height ~= 8 then
    return false,
      Errors.new(MANIFEST_INVALID, what .. " must be the " .. width .. "x8 HGSS strip", {
        what = what,
        width = rect.width,
        height = rect.height,
      })
  end
  return true
end

---@param context FieldUiAssetCache.ValidationContext
---@param sectionName string
---@param validator fun(context: FieldUiAssetCache.ValidationContext, section: table): boolean, Errors.Error?
---@return boolean, Errors.Error?
local function validateSection(context, sectionName, validator)
  local section = context.manifest[sectionName]
  if type(section) ~= "table" then
    return false,
      Errors.new(MANIFEST_INVALID, "manifest section " .. sectionName .. " must be a table", {
        section = sectionName,
      })
  end
  return validator(context, section)
end

---@param context FieldUiAssetCache.ValidationContext
---@param section table
---@return boolean, Errors.Error?
local function validateDialogueFrames(context, section)
  if type(section.count) ~= "number" or section.count % 1 ~= 0 or section.count < 1 then
    return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.count must be a positive integer", {})
  end
  if type(section.frameTiles) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.frameTiles must be a table", {})
  end
  for frame = 0, section.count - 1 do
    local frameTiles = section.frameTiles ---@type table<integer, FieldUiAssetCache.Rect>
    local frameTilesOk, frameTilesErr = stripInAtlas(
      context,
      frameTiles[frame],
      FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES,
      "frame " .. frame .. " tiles",
      FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
    )
    if not frameTilesOk then
      return false, frameTilesErr
    end
  end
  local cursor = section.continueCursor ---@type table
  if type(cursor) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.continueCursor must be a table", {})
  end
  local cursorAsset = cursor.asset ---@type string
  local asset = context.atlasSizes[cursorAsset] ---@type { width: integer, height: integer }?
  if cursorAsset ~= FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR or not asset then
    return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.continueCursor.asset is invalid", {})
  end
  if asset.width ~= 48 or asset.height ~= section.count * 16 then
    return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor atlas has invalid dimensions", {})
  end
  if type(cursor.cycle) ~= "table" or #cursor.cycle ~= 4 then
    return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor cycle is invalid", {})
  end
  local cycle = cursor.cycle ---@type integer[]
  for index, phase in ipairs({ 0, 1, 2, 1 }) do
    if cycle[index] ~= phase then
      return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor cycle is not source-faithful", {})
    end
  end
  if cursor.framePrinterTicks ~= 9 then
    return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor timing is invalid", {})
  end
  local placement = cursor.placement ---@type FieldUiAssetCache.Rect
  if
    type(placement) ~= "table"
    or placement.x ~= 240
    or placement.y ~= 168
    or placement.width ~= 16
    or placement.height ~= 16
  then
    return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor placement is invalid", {})
  end
  if type(cursor.styles) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor styles are missing", {})
  end
  local styles = cursor.styles ---@type table<integer, table>
  for style = 0, section.count - 1 do
    local styleEntry = styles[style] ---@type table
    if type(styleEntry) ~= "table" or type(styleEntry.phases) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor style is missing", { style = style })
    end
    local phases = styleEntry.phases ---@type table<integer, FieldUiAssetCache.Rect>
    for phase = 0, 2 do
      local rect = phases[phase] ---@type FieldUiAssetCache.Rect
      local expected = { x = phase * 16, y = style * 16, width = 16, height = 16 }
      if
        type(rect) ~= "table"
        or rect.x ~= expected.x
        or rect.y ~= expected.y
        or rect.width ~= expected.width
        or rect.height ~= expected.height
      then
        return false,
          Errors.new(MANIFEST_INVALID, "dialogue continuation cursor phase is invalid", {
            style = style,
            phase = phase,
          })
      end
      local phaseOk, phaseErr = rectInAtlas(context, rect, cursorAsset, "dialogue continuation cursor phase")
      if not phaseOk then
        return false, phaseErr
      end
    end
  end
  return true
end

---@param slot number
---@param name string
---@return boolean, Errors.Error?
local function validateSignpostSlot(slot, name)
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 15 then
    return false,
      Errors.new(MANIFEST_INVALID, "signposts.textColors." .. name .. " must be an integral slot 0..15", {
        name = name,
        value = slot,
      })
  end
  return true
end

---@param textColors table
---@return boolean, Errors.Error?
local function validateSignpostTextColors(textColors)
  if type(textColors) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "signposts.textColors must be a table", {})
  end
  local foregroundOk, foregroundErr = validateSignpostSlot(textColors.foreground, "foreground")
  if not foregroundOk then
    return false, foregroundErr
  end
  if textColors.foreground ~= 2 then
    return false,
      Errors.new(MANIFEST_INVALID, "signposts.textColors.foreground must be slot 2 (HGSS contract)", {
        value = textColors.foreground,
      })
  end
  local shadowOk, shadowErr = validateSignpostSlot(textColors.shadow, "shadow")
  if not shadowOk then
    return false, shadowErr
  end
  if textColors.shadow ~= 10 then
    return false,
      Errors.new(MANIFEST_INVALID, "signposts.textColors.shadow must be slot 10 (HGSS contract)", {
        value = textColors.shadow,
      })
  end
  local backgroundOk, backgroundErr = validateSignpostSlot(textColors.background, "background")
  if not backgroundOk then
    return false, backgroundErr
  end
  if textColors.background ~= 15 then
    return false,
      Errors.new(MANIFEST_INVALID, "signposts.textColors.background must be slot 15 (HGSS contract)", {
        value = textColors.background,
      })
  end
  return true
end

---@param value number
---@return boolean
local function validPaletteComponent(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 255
end

---@param typeKey number
---@param palette table
---@return boolean, Errors.Error?
local function validateSignpostPalette(typeKey, palette)
  if type(palette) ~= "table" then
    return false,
      Errors.new(MANIFEST_INVALID, "signpost type " .. typeKey .. " palette must be a table", {
        type = typeKey,
      })
  end
  for slot = 0, 15 do
    local color = palette[slot]
    if color == nil then
      return false,
        Errors.new(MANIFEST_INVALID, "signpost type " .. typeKey .. " palette slot " .. slot .. " is missing", {
          type = typeKey,
          slot = slot,
        })
    end
    if
      type(color) ~= "table"
      or not validPaletteComponent(color.r)
      or not validPaletteComponent(color.g)
      or not validPaletteComponent(color.b)
    then
      return false,
        Errors.new(
          MANIFEST_INVALID,
          "signpost type " .. typeKey .. " palette slot " .. slot .. " must have integral r/g/b 0..255",
          {
            type = typeKey,
            slot = slot,
          }
        )
    end
  end
  local paletteKeyCount = 0
  for _ in pairs(palette) do
    paletteKeyCount = paletteKeyCount + 1
  end
  if paletteKeyCount ~= 16 then
    return false,
      Errors.new(MANIFEST_INVALID, "signpost type " .. typeKey .. " palette must have exactly 16 entries (0..15)", {
        type = typeKey,
        count = paletteKeyCount,
      })
  end
  return true
end

---@param context FieldUiAssetCache.ValidationContext
---@param typeKey number
---@param typeEntry table
---@return boolean, Errors.Error?
local function validateSignpostType(context, typeKey, typeEntry)
  if type(typeEntry) ~= "table" or typeEntry.sourceType ~= typeKey then
    return false,
      Errors.new(MANIFEST_INVALID, "signpost type entries must be keyed by their own sourceType", {
        key = typeKey,
      })
  end
  local paletteOk, paletteErr = validateSignpostPalette(typeKey, typeEntry.palette)
  if not paletteOk then
    return false, paletteErr
  end
  if type(typeEntry.frameTiles) ~= "table" then
    return false,
      Errors.new(MANIFEST_INVALID, "signpost type " .. typeKey .. " frameTiles must be a table", {
        type = typeKey,
      })
  end
  local frameTilesOk, frameTilesErr = stripInAtlas(
    context,
    typeEntry.frameTiles,
    FieldUiAssetCache.ASSET.SIGNPOST_TILES,
    "signpost type " .. typeKey .. " frameTiles",
    FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
  )
  if not frameTilesOk then
    return false, frameTilesErr
  end
  if typeEntry.wayfinding ~= nil then
    if type(typeEntry.wayfinding) ~= "table" or next(typeEntry.wayfinding) == nil then
      return false, Errors.new(MANIFEST_INVALID, "signpost wayfinding must be a non-empty per-map table", {})
    end
    local wayfinding = typeEntry.wayfinding ---@type table<number, FieldUiAssetCache.Rect>
    for map, rect in pairs(wayfinding) do
      if type(map) ~= "number" or map % 1 ~= 0 or map < 0 then
        return false,
          Errors.new(MANIFEST_INVALID, "signpost wayfinding map keys must be non-negative integers", { map = map })
      end
      local wayfindingOk, wayfindingErr =
        rectInAtlas(context, rect, FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING, "signpost wayfinding map " .. map)
      if not wayfindingOk then
        return false, wayfindingErr
      end
      if
        rect.width ~= FieldUiAssetCache.GEOMETRY.WAYFINDING_WIDTH
        or rect.height ~= FieldUiAssetCache.GEOMETRY.WAYFINDING_HEIGHT
      then
        return false,
          Errors.new(MANIFEST_INVALID, "signpost wayfinding map " .. map .. " must be the 48x32 final surface", {
            what = "signpost wayfinding map " .. map,
            width = rect.width,
            height = rect.height,
          })
      end
    end
  end
  return true
end

---@param context FieldUiAssetCache.ValidationContext
---@param section table
---@return boolean, Errors.Error?
local function validateSignposts(context, section)
  local textColorsOk, textColorsErr = validateSignpostTextColors(section.textColors)
  if not textColorsOk then
    return false, textColorsErr
  end
  if type(section.types) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "signposts.types must be a table", {})
  end
  local signpostTypes = section.types ---@type table<number, table>
  for key, typeEntry in pairs(signpostTypes) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 0 then
      return false, Errors.new(MANIFEST_INVALID, "signpost type keys must be non-negative integers", { key = key })
    end
    local typeOk, typeErr = validateSignpostType(context, key, typeEntry)
    if not typeOk then
      return false, typeErr
    end
  end
  return true
end

---@param context FieldUiAssetCache.ValidationContext
---@param section table
---@return boolean, Errors.Error?
local function validateStartMenu(context, section)
  local backgroundOk, backgroundErr =
    rectInAtlas(context, section.background, FieldUiAssetCache.ASSET.START_MENU_BACKGROUND, "start menu background")
  if not backgroundOk then
    return false, backgroundErr
  end
  if type(section.cursor) ~= "table" or type(section.cursor.frames) ~= "table" or #section.cursor.frames < 1 then
    return false, Errors.new(MANIFEST_INVALID, "startMenu.cursor must carry at least one frame", {})
  end
  local frames = section.cursor.frames ---@type table[]
  for _, frameEntry in ipairs(frames) do
    local frameOk, frameErr =
      rectInAtlas(context, frameEntry, FieldUiAssetCache.ASSET.START_MENU_CURSOR, "start menu cursor frame")
    if not frameOk then
      return false, frameErr
    end
    if type(frameEntry.duration) ~= "number" or frameEntry.duration % 1 ~= 0 or frameEntry.duration < 1 then
      return false, Errors.new(MANIFEST_INVALID, "cursor frame duration must be a positive integer", {})
    end
  end
  if type(section.slots) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "startMenu.slots must be a table", {})
  end
  local slotCount = 0
  local slots = section.slots ---@type table<integer, FieldUiAssetCache.Rect>
  for _ in pairs(slots) do
    slotCount = slotCount + 1
  end
  if slotCount ~= 10 then
    return false, Errors.new(MANIFEST_INVALID, "startMenu.slots must be exactly the ten-slot grid", {})
  end
  for id = 1, 10 do
    local slot = slots[id]
    if slot == nil then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.slots must be the dense 1..10 grid", {})
    end
    local slotOk, slotErr =
      rectInAtlas(context, slot, FieldUiAssetCache.ASSET.START_MENU_BACKGROUND, "start menu slot " .. id)
    if not slotOk then
      return false, slotErr
    end
  end
  return true
end

---@param context FieldUiAssetCache.ValidationContext
---@param section table
---@return boolean, Errors.Error?
local function validateTrainerCard(context, section)
  local frontOk, frontErr =
    rectInAtlas(context, section.front, FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT, "trainer card front")
  if not frontOk then
    return false, frontErr
  end
  return true
end

---@param manifest FieldUiAssetCache.Manifest
---@return boolean, Errors.Error?
function FieldUiAssetCache.validateManifest(manifest)
  if type(manifest) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "manifest is not a table", {})
  end
  if manifest.schema ~= FieldUiAssetCache.SCHEMA then
    return false,
      Errors.new(MANIFEST_INVALID, "manifest schema mismatch", {
        schema = manifest.schema,
        expected = FieldUiAssetCache.SCHEMA,
      })
  end
  if type(manifest.reference) ~= "table" or manifest.reference.width ~= 256 or manifest.reference.height ~= 192 then
    return false,
      Errors.new(MANIFEST_INVALID, "manifest reference must be the 256x192 field screen", {
        reference = type(manifest.reference),
      })
  end
  local assetsOk, contextOrError = validateAssets(manifest)
  if not assetsOk then
    ---@cast contextOrError Errors.Error
    return false, contextOrError
  end
  ---@cast contextOrError FieldUiAssetCache.ValidationContext
  local context = contextOrError ---@type FieldUiAssetCache.ValidationContext

  local dialogueOk, dialogueErr = validateSection(context, "dialogueFrames", validateDialogueFrames)
  if not dialogueOk then
    return false, dialogueErr
  end

  local signpostOk, signpostErr = validateSection(context, "signposts", validateSignposts)
  if not signpostOk then
    return false, signpostErr
  end

  local startMenuOk, startMenuErr = validateSection(context, "startMenu", validateStartMenu)
  if not startMenuOk then
    return false, startMenuErr
  end

  local trainerCardOk, trainerCardErr = validateSection(context, "trainerCard", validateTrainerCard)
  if not trainerCardOk then
    return false, trainerCardErr
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
  local manifest = cacheFs:loadLua(FieldUiAssetCache.manifestPath()) ---@type FieldUiAssetCache.Manifest?
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
