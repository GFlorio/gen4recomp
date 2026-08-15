-- Synthetic field-UI fixtures for the dialogue frame, window style, signpost,
-- and Start Menu surface work: a generated-shape `ui.lua` manifest carrying
-- two dialogue frame strips (18 tiles of 8x8 stacked per frame, like the
-- compiled class), the signpost frame strip and wayfinding atlas (one
-- per-(type,map) row, map 0 and map 1 visibly distinct), the signpost
-- source-type map (the full 25-type corpus set, types 0/1 with per-map
-- wayfinding rects), and the Start Menu surface (background, slot grid,
-- cursor frames), plus cache builders that carry the dialogue font and/or
-- the Start Menu assets. Frame tiles are solid per-tile colors from
-- two distinct palettes (frame 0 blue family, frame 1 cream family, mirroring
-- the real compiled frames' variety) and each Start Menu slot/cursor frame is
-- a distinct color, so a misplacement or wrong rect is a pixel mismatch,
-- never a wash.

local PngWriter = require("libs.assets.src.PngWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")

local FieldUiFixture = {}

FieldUiFixture.STRIP_PATH = "assets/generated/field/ui/dialogue-frame-tiles.png"
FieldUiFixture.TILES_PER_FRAME = 18
FieldUiFixture.FRAME_COUNT = 2

FieldUiFixture.SIGNPOST_TILES_PATH = "assets/generated/field/ui/signpost-tiles.png"
FieldUiFixture.WAYFINDING_PATH = "assets/generated/field/ui/wayfinding-tiles.png"

FieldUiFixture.START_MENU_BACKGROUND_PATH = "assets/generated/field/ui/start-menu.png"
FieldUiFixture.START_MENU_CURSOR_PATH = "assets/generated/field/ui/start-menu-cursor.png"
FieldUiFixture.TRAINER_CARD_PATH = "assets/generated/field/ui/trainer-card.png"

-- Every signpost source type the real scr_seq corpus uses (opcodes 55/56),
-- the set pinned by the producer configuration; types 0/1 reserve the
-- wayfinding graphic.
FieldUiFixture.CORPUS_SOURCE_TYPES = {
  0,
  1,
  2,
  3,
  4,
  5,
  8,
  9,
  10,
  11,
  13,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  23,
  28,
  29,
  30,
  33,
  34,
  39,
}

-- Palette A: blue family. Tile i is a distinct color of the family.
local function paletteA(i)
  return (i * 13) % 256, 140 + (i * 7) % 90, 255 - (i * 11) % 40
end

-- Palette B: cream family, every tile distinct from its frame-0 counterpart.
local function paletteB(i)
  return 255 - (i * 12) % 90, 210 + (i * 3) % 30, 140 + (i * 17) % 90
end

local function tileBytes(i, palette)
  local r, g, b = palette(i)
  return string.rep(string.char(r, g, b, 255), 64)
end

-- The strip atlas: frame rows stacked, each row the 18 tiles of one frame.
---@return string png
function FieldUiFixture.stripBytes()
  local rgba = {}
  for frame = 0, FieldUiFixture.FRAME_COUNT - 1 do
    local palette = frame == 0 and paletteA or paletteB
    for tile = 0, FieldUiFixture.TILES_PER_FRAME - 1 do
      rgba[#rgba + 1] = tileBytes(tile, palette)
    end
  end
  return PngWriter.encode(144, FieldUiFixture.FRAME_COUNT * 8, table.concat(rgba))
end

-- The raw RGBA rows of one frame row (144x8), so tests can compose an
-- independent expected render from the tile bytes.
---@param frame integer
---@return string rgba
function FieldUiFixture.framePixels(frame)
  local palette = frame == 0 and paletteA or paletteB
  local rows = {}
  for tile = 0, FieldUiFixture.TILES_PER_FRAME - 1 do
    rows[#rows + 1] = tileBytes(tile, palette)
  end
  return table.concat(rows)
end

-- Tile i of the signpost frame strip: a distinct solid color, so a wrong
-- placement (or a divider swap for tile 8) is a pixel mismatch in the
-- goldens.
local function signpostTileColor(i)
  return (40 + i * 12) % 256, (90 + i * 7) % 220, (210 - i * 9) % 180
end

-- Tile t of a wayfinding row: distinct within the row, and every atlas row
-- (one per (type, map) pair) uses a distinct color family so a wrong-row
-- sample is a mismatch.
local function wayfindingTileColor(row, tile)
  return (50 + tile * 9) % 256, (120 + row * 40) % 256, (30 + tile * 11) % 256
end

-- The raw 8x8 RGBA bytes of one signpost frame-strip tile.
---@param tile integer
---@return string rgba
function FieldUiFixture.signpostTilePixels(tile)
  local r, g, b = signpostTileColor(tile)
  return string.rep(string.char(r, g, b, 255), 64)
end

-- The whole signpost frame strip: 18 distinct tiles in one 144x8 row, laid
-- out pixel-row by pixel-row (concatenating 8x8 tile blocks would not match
-- the 144-wide row layout).
---@return string png
function FieldUiFixture.signpostTilesBytes()
  local bytes = {}
  for y = 0, 7 do
    for x = 0, 143 do
      local r, g, b = signpostTileColor(math.floor(x / 8))
      bytes[#bytes + 1] = string.char(r, g, b, 255)
    end
  end
  return PngWriter.encode(144, 8, table.concat(bytes))
end

-- The raw RGBA bytes of one wayfinding atlas row (each (type, map) pair has
-- its own row): 24 distinct tiles in a 192x8 pixel row.
---@param rowY integer
---@return string rgba
function FieldUiFixture.wayfindingRowPixels(rowY)
  local row = math.floor(rowY / 8)
  local bytes = {}
  for y = 0, 7 do
    for x = 0, 191 do
      local r, g, b = wayfindingTileColor(row, math.floor(x / 8))
      bytes[#bytes + 1] = string.char(r, g, b, 255)
    end
  end
  return table.concat(bytes)
end

-- The wayfinding atlas: one row per (type, map) pair in the manifest --
-- type 0 at rows y=0 (map 0) and y=8 (map 1), type 1 at rows y=16 (map 0)
-- and y=24 (map 1). Every row has its own color family, so a wrong-row
-- sample is a mismatch.
---@return string png
function FieldUiFixture.wayfindingBytes()
  local rows = {}
  for block = 0, 3 do
    local rgba = FieldUiFixture.wayfindingRowPixels(block * 8)
    for i = 0, 7 do
      rows[#rows + 1] = rgba:sub(i * 768 + 1, (i + 1) * 768)
    end
  end
  return PngWriter.encode(192, 32, table.concat(rows))
end

-- The canonical Start Menu logical action-slot grid (the manifest's own
-- metadata shape): ten 128x38 rects in two columns of five. The fixture
-- values mirror the compiled class; the runtime renderer must resolve them
-- from the manifest, never hard-code them.
FieldUiFixture.START_MENU_SLOTS = {
  [1] = { x = 0, y = 0, width = 128, height = 38 },
  [2] = { x = 128, y = 0, width = 128, height = 38 },
  [3] = { x = 0, y = 38, width = 128, height = 38 },
  [4] = { x = 128, y = 38, width = 128, height = 38 },
  [5] = { x = 0, y = 76, width = 128, height = 38 },
  [6] = { x = 128, y = 76, width = 128, height = 38 },
  [7] = { x = 0, y = 114, width = 128, height = 38 },
  [8] = { x = 128, y = 114, width = 128, height = 38 },
  [9] = { x = 0, y = 152, width = 128, height = 38 },
  [10] = { x = 128, y = 152, width = 128, height = 38 },
}

-- Two distinct cursor frames in a 16x32 atlas (frame 1 row y=0, frame 2 row
-- y=16) with distinct durations, so the fixed-tick cadence is pixel-visible
-- in the goldens and the durations are observable in unit tests.
FieldUiFixture.START_MENU_CURSOR_FRAMES = {
  { x = 0, y = 0, width = 16, height = 16, duration = 22 },
  { x = 0, y = 16, width = 16, height = 16, duration = 11 },
}

-- The solid color of one Start Menu slot region; every slot is a distinct
-- color so a wrong placement is a pixel mismatch in the goldens.
---@param slotId integer
---@return integer, integer, integer
function FieldUiFixture.startMenuSlotColor(slotId)
  return (10 + slotId * 21) % 256, (90 + slotId * 17) % 200, (220 - slotId * 13) % 240
end

-- The slot containing the pixel (x, y), or nil outside the grid (the two
-- bottom rows of the 256x192 surface are uncovered).
---@param x integer
---@param y integer
---@return integer?
function FieldUiFixture.slotIdAt(x, y)
  for slotId, rect in pairs(FieldUiFixture.START_MENU_SLOTS) do
    if x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height then
      return slotId
    end
  end
  return nil
end

-- The background surface: each slot region is its slot's solid color; the
-- uncovered rows are transparent.
---@return string png
function FieldUiFixture.startMenuBackgroundBytes()
  local bytes = {}
  for y = 0, 191 do
    for x = 0, 255 do
      local slotId = FieldUiFixture.slotIdAt(x, y)
      if slotId then
        local r, g, b = FieldUiFixture.startMenuSlotColor(slotId)
        bytes[#bytes + 1] = string.char(r, g, b, 255)
      else
        bytes[#bytes + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return PngWriter.encode(256, 192, table.concat(bytes))
end

-- The solid color of one cursor frame; the two frames are distinct colors.
---@param frame integer 1-based
---@return integer, integer, integer
function FieldUiFixture.startMenuCursorColor(frame)
  if frame == 1 then
    return 255, 0, 255
  end
  return 0, 255, 255
end

-- The cursor atlas: two distinct 16x16 frames stacked (frame 1 at y=0,
-- frame 2 at y=16), so a wrong frame index is a pixel mismatch.
---@return string png
function FieldUiFixture.startMenuCursorBytes()
  local bytes = {}
  for y = 0, 31 do
    local r, g, b = FieldUiFixture.startMenuCursorColor(y < 16 and 1 or 2)
    bytes[#bytes + 1] = string.rep(string.char(r, g, b, 255), 16)
  end
  return PngWriter.encode(16, 32, table.concat(bytes))
end

-- The trainer card front art: a per-tile tinted surface (every 8x8 tile a
-- distinct color so a misplacement is a pixel mismatch), with the bottom 64
-- rows transparent exactly like the compiled class (the DS screen buffer is
-- 32x32 tiles but the visible card fills the 256x192 screen).
---@return string png
function FieldUiFixture.cardBytes()
  local bytes = {}
  for y = 0, 255 do
    for x = 0, 255 do
      if y < 192 then
        local tileX = math.floor(x / 8)
        local tileY = math.floor(y / 8)
        local r = (10 + tileX * 23 + tileY * 7) % 256
        local g = (30 + tileY * 41 + tileX * 5) % 256
        local b = (200 - tileX * 13 - tileY * 17) % 256
        bytes[#bytes + 1] = string.char(r, g, b, 255)
      else
        bytes[#bytes + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return PngWriter.encode(256, 256, table.concat(bytes))
end

-- The trainer card label/value charset: the fixture font carries every
-- character the audited front-side labels and values can draw (A-Z, a-z for
-- the "No." label, digits, space, period). Codes 1..64 in the first atlas
-- row; the fallback glyph 0 sits in the second row.
FieldUiFixture.CARD_CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789."

-- The solid color of card glyph code i: distinct per code, so a wrong glyph
-- (or a wrong anchor) is a pixel mismatch in the goldens.
---@param code integer
---@return integer, integer, integer
function FieldUiFixture.cardGlyphColor(code)
  return (code * 37) % 256, (60 + code * 13) % 200, (200 - code * 11) % 180
end

---@return FieldFontDef
function FieldUiFixture.cardFontDef()
  local glyphs = {}
  for code = 1, #FieldUiFixture.CARD_CHARSET do
    glyphs[code] = { x = (code - 1) * 8, y = 0, w = 8, h = 16, advance = 8, bearingX = 0, bearingY = 0 }
  end
  glyphs[0] = { x = 0, y = 16, w = 8, h = 16, advance = 8, bearingX = 0, bearingY = 0 }
  local charmap = {}
  for index = 1, #FieldUiFixture.CARD_CHARSET do
    charmap[FieldUiFixture.CARD_CHARSET:sub(index, index)] = index
  end
  return {
    schema = "g4-field-font-v1",
    fontId = 0,
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    atlas = { width = 512, height = 32, glyphsPerRow = 64, glyphWidth = 8, glyphHeight = 16 },
    glyphs = glyphs,
    charmap = charmap,
  }
end

-- The card font plus one real multibyte glyph: É (U+00C9, a two-byte UTF-8
-- sequence) at compiled code 360 with advance 6, mirroring the generated
-- heartgold field font, so multibyte names exercise the shared text path.
---@return FieldFontDef
function FieldUiFixture.cardFontDefWithMultibyte()
  local def = FieldUiFixture.cardFontDef()
  def.glyphs[360] = { x = (360 - 1) * 8, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 }
  def.charmap["\195\137"] = 360
  return def
end

-- The card font atlas: glyph codes 1..64 in the first 512x16 row, the
-- fallback in the second row.
---@return string png
function FieldUiFixture.cardFontAtlasBytes()
  local bytes = {}
  for y = 0, 31 do
    for x = 0, 511 do
      local code = y < 16 and (math.floor(x / 8) + 1) or 0
      local r, g, b = FieldUiFixture.cardGlyphColor(code)
      bytes[#bytes + 1] = string.char(r, g, b, 255)
    end
  end
  return PngWriter.encode(512, 32, table.concat(bytes))
end

-- The signpost source-type map in the generated manifest shape: every corpus
-- type with its raw number preserved, types 0/1 carrying a per-map wayfinding
-- table (map -> atlas rect; each pair has its own atlas row, so the map-0 and
-- map-1 rects are visibly distinct). The on-screen 56px graphic region is NOT
-- the atlas rect; the style loader derives the region from the presence of
-- the table, never its pixels.
---@return table
function FieldUiFixture.signpostTypes()
  local types = {}
  for _, sourceType in ipairs(FieldUiFixture.CORPUS_SOURCE_TYPES) do
    local entry = { sourceType = sourceType }
    if sourceType == 0 then
      entry.wayfinding = {
        [0] = { x = 0, y = 0, width = 192, height = 8 },
        [1] = { x = 0, y = 8, width = 192, height = 8 },
      }
    elseif sourceType == 1 then
      entry.wayfinding = {
        [0] = { x = 0, y = 16, width = 192, height = 8 },
        [1] = { x = 0, y = 24, width = 192, height = 8 },
      }
    end
    types[sourceType] = entry
  end
  return types
end

-- The manifest shape the renderer consumes: the asset entry naming the strip
-- and the frame tile rects inside it, plus the signpost frame/wayfinding
-- assets and source-type map.
---@return table
function FieldUiFixture.manifest()
  return {
    schema = FieldUiAssetCache.SCHEMA,
    assets = {
      [FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES] = {
        image = FieldUiFixture.STRIP_PATH,
        width = 144,
        height = FieldUiFixture.FRAME_COUNT * 8,
      },
      [FieldUiAssetCache.ASSET.SIGNPOST_TILES] = {
        image = FieldUiFixture.SIGNPOST_TILES_PATH,
        width = 144,
        height = 8,
      },
      [FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING] = {
        image = FieldUiFixture.WAYFINDING_PATH,
        width = 192,
        height = 32,
      },
      [FieldUiAssetCache.ASSET.START_MENU_BACKGROUND] = {
        image = FieldUiFixture.START_MENU_BACKGROUND_PATH,
        width = 256,
        height = 192,
      },
      [FieldUiAssetCache.ASSET.START_MENU_CURSOR] = {
        image = FieldUiFixture.START_MENU_CURSOR_PATH,
        width = 16,
        height = 32,
      },
      [FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT] = {
        image = FieldUiFixture.TRAINER_CARD_PATH,
        width = 256,
        height = 256,
      },
    },
    dialogueFrames = {
      count = FieldUiFixture.FRAME_COUNT,
      frameTiles = {
        [0] = { x = 0, y = 0, width = 144, height = 8 },
        [1] = { x = 0, y = 8, width = 144, height = 8 },
      },
      palettes = {
        [0] = { colors = { { r = 1, g = 2, b = 3 } } },
        [1] = { colors = { { r = 4, g = 5, b = 6 } } },
      },
    },
    signposts = {
      frame = {
        tiles = { x = 0, y = 0, width = 144, height = 8 },
      },
      types = FieldUiFixture.signpostTypes(),
    },
    startMenu = {
      background = { x = 0, y = 0, width = 256, height = 192 },
      cursor = { frames = FieldUiFixture.START_MENU_CURSOR_FRAMES },
      slots = FieldUiFixture.START_MENU_SLOTS,
    },
    trainerCard = {
      front = { x = 0, y = 0, width = 256, height = 256 },
    },
  }
end

---@return CacheFs
function FieldUiFixture.cacheWithFontAndFrames()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.STRIP_PATH, FieldUiFixture.stripBytes())
  cache:write(FieldUiFixture.SIGNPOST_TILES_PATH, FieldUiFixture.signpostTilesBytes())
  cache:write(FieldUiFixture.WAYFINDING_PATH, FieldUiFixture.wayfindingBytes())
  cache:write(FieldUiFixture.START_MENU_BACKGROUND_PATH, FieldUiFixture.startMenuBackgroundBytes())
  cache:write(FieldUiFixture.START_MENU_CURSOR_PATH, FieldUiFixture.startMenuCursorBytes())
  return cache
end

-- The trainer card front viewer fixture: the card font (the full label/value
-- charset, or the caller's own font definition), the field-UI manifest with
-- the trainerCard section, and the synthetic 256x256 card front art.
---@param fontDef FieldFontDef?
---@return CacheFs
function FieldUiFixture.trainerCardCache(fontDef)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua("data/generated/field/font/font-0.lua", fontDef or FieldUiFixture.cardFontDef())
  cache:write("assets/generated/field/font/font-0.png", FieldUiFixture.cardFontAtlasBytes())
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  return cache
end

-- The same manifest and Start Menu assets without the dialogue font: the
-- Start Menu surface carries its art baked into the background image, so its
-- renderer needs no font atlas.
---@return CacheFs
function FieldUiFixture.startMenuCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.START_MENU_BACKGROUND_PATH, FieldUiFixture.startMenuBackgroundBytes())
  cache:write(FieldUiFixture.START_MENU_CURSOR_PATH, FieldUiFixture.startMenuCursorBytes())
  return cache
end

return FieldUiFixture
