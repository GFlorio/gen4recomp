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
  cache:write(
    FieldUiFixture.SIGNPOST_TILES_PATH,
    PngWriter.encode(144, 8, string.rep(string.char(90, 90, 90, 255), 144 * 8))
  )
  cache:write(
    FieldUiFixture.WAYFINDING_PATH,
    PngWriter.encode(192, 32, string.rep(string.char(60, 120, 60, 255), 192 * 32))
  )
  return cache
end

return FieldUiFixture
