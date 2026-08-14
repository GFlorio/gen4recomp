-- Synthetic field-UI fixtures for the dialogue frame and window style work: a
-- generated-shape `ui.lua` manifest carrying two dialogue frame strips (18
-- tiles of 8x8 stacked per frame, like the compiled class), the signpost
-- frame strip and wayfinding atlas, and the signpost source-type map (the
-- full 25-type corpus set, types 0/1 with wayfinding rects), plus a cache
-- builder that also carries the dialogue font. Frame tiles are solid per-tile
-- colors from two distinct palettes (frame 0 blue family, frame 1 cream
-- family, mirroring the real compiled frames' variety), so a misplacement or
-- wrong-frame rect is a pixel mismatch, never a wash.

local PngWriter = require("libs.assets.src.PngWriter")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")

local FieldUiFixture = {}

FieldUiFixture.STRIP_PATH = "assets/generated/field/ui/dialogue-frame-tiles.png"
FieldUiFixture.TILES_PER_FRAME = 18
FieldUiFixture.FRAME_COUNT = 2

FieldUiFixture.SIGNPOST_TILES_PATH = "assets/generated/field/ui/signpost-tiles.png"
FieldUiFixture.WAYFINDING_PATH = "assets/generated/field/ui/wayfinding-tiles.png"

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

-- Tile t of a wayfinding row: distinct within the row, and the two rows
-- (y=0 and y=16 in the atlas) use distinct color families so a wrong-row
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

-- The raw RGBA bytes of one wayfinding atlas row (the manifest rect for
-- type 0 is y=0, for type 1 y=16): 24 distinct tiles in a 192x8 pixel row.
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

-- The wayfinding atlas: rows y=0 and y=16 carry the type 0/1 graphic rows;
-- the other rows are fully transparent so a wrong-row sample is a mismatch.
---@return string png
function FieldUiFixture.wayfindingBytes()
  local rows = {}
  for block = 0, 3 do
    if block == 0 or block == 2 then
      local rgba = FieldUiFixture.wayfindingRowPixels(block * 8)
      for i = 0, 7 do
        rows[#rows + 1] = rgba:sub(i * 768 + 1, (i + 1) * 768)
      end
    else
      for _ = 1, 8 do
        rows[#rows + 1] = string.rep(string.char(0, 0, 0, 0), 192)
      end
    end
  end
  return PngWriter.encode(192, 32, table.concat(rows))
end

-- The signpost source-type map in the generated manifest shape: every corpus
-- type with its raw number preserved, types 0/1 carrying wayfinding atlas
-- rects. The on-screen 56px graphic region is NOT the atlas rect; the style
-- loader derives the region from the presence of the rect, never its pixels.
---@return table
function FieldUiFixture.signpostTypes()
  local types = {}
  for _, sourceType in ipairs(FieldUiFixture.CORPUS_SOURCE_TYPES) do
    local entry = { sourceType = sourceType }
    if sourceType == 0 then
      entry.wayfinding = { x = 0, y = 0, width = 192, height = 8 }
    elseif sourceType == 1 then
      entry.wayfinding = { x = 0, y = 16, width = 192, height = 8 }
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
      ["hgss.dialogue_frame.tiles"] = {
        image = FieldUiFixture.STRIP_PATH,
        width = 144,
        height = FieldUiFixture.FRAME_COUNT * 8,
      },
      ["hgss.signpost.tiles"] = {
        image = FieldUiFixture.SIGNPOST_TILES_PATH,
        width = 144,
        height = 8,
      },
      ["hgss.signpost.wayfinding"] = {
        image = FieldUiFixture.WAYFINDING_PATH,
        width = 192,
        height = 32,
      },
    },
    dialogueFrames = {
      count = FieldUiFixture.FRAME_COUNT,
      frameTiles = {
        [0] = { x = 0, y = 0, width = 144, height = 8 },
        [1] = { x = 0, y = 8, width = 144, height = 8 },
      },
    },
    signposts = {
      frame = {
        tiles = { x = 0, y = 0, width = 144, height = 8 },
      },
      types = FieldUiFixture.signpostTypes(),
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
  return cache
end

return FieldUiFixture
