-- Synthetic field-UI fixtures for the dialogue frame work: a generated-shape
-- `ui.lua` manifest carrying two dialogue frame strips (18 tiles of 8x8
-- stacked per frame, like the compiled class) and the PNG atlas holding them,
-- plus a cache builder that also carries the dialogue font. Frame tiles are
-- solid per-tile colors from two distinct palettes (frame 0 blue family,
-- frame 1 cream family, mirroring the real compiled frames' variety), so a
-- misplacement or wrong-frame rect is a pixel mismatch, never a wash.

local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")

local FieldUiFixture = {}

FieldUiFixture.STRIP_PATH = "assets/generated/field/ui/dialogue-frame-tiles.png"
FieldUiFixture.TILES_PER_FRAME = 18
FieldUiFixture.FRAME_COUNT = 2

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

-- The manifest shape the renderer consumes: the asset entry naming the strip
-- and the frame tile rects inside it.
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
    },
    dialogueFrames = {
      count = FieldUiFixture.FRAME_COUNT,
      frameTiles = {
        [0] = { x = 0, y = 0, width = 144, height = 8 },
        [1] = { x = 0, y = 8, width = 144, height = 8 },
      },
    },
  }
end

---@return CacheFs
function FieldUiFixture.cacheWithFontAndFrames()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.STRIP_PATH, FieldUiFixture.stripBytes())
  return cache
end

return FieldUiFixture
