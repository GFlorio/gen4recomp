-- ROM-conformance facts for the generated field-UI class: the real private
-- dump compiles the bundle (frames, signposts, Start Menu, Trainer Card),
-- every indexed file passes FieldUiAssetCache.isReady, and the compile is
-- deterministic. Asserts only non-copyright structural facts.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local PngReader = require("tests.support.PngReader")
local FieldUiCompiler = require("romdump.src.digest.FieldUiCompiler")
local FieldUiCacheWriter = require("romdump.src.digest.FieldUiCacheWriter")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local Hashing = require("romdump.src.digest.Hashing")

local T = {}

function T.compiled_ui_assets_are_ready_and_stable(romFs, version)
  local cache = CacheFs.forVersion(version)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local marker = FieldUiAssetCache.marker(romFs:metadata().sha1, Hashing.hashLua(bundle.dependencies))
  Assert.equal(bundle.marker, marker, "the marker is FORMAT:romSha1:depHash")

  -- The class covers every section the manifest contract requires.
  Assert.equal(bundle.manifest.dialogueFrames.count, 20)
  Assert.isTrue(bundle.manifest.signposts.types[0].wayfinding ~= nil, "type 0 reserves the wayfinding region")
  Assert.isTrue(bundle.manifest.signposts.types[2].wayfinding == nil, "type 2 is full width")
  Assert.equal(bundle.manifest.startMenu.background.width, 256)
  Assert.equal(bundle.manifest.trainerCard.front.width, 256)

  -- Recompiling is deterministic and the published class is fully ready.
  local second = assert(FieldUiCompiler.compile(romFs))
  Assert.equal(second.marker, bundle.marker)
  FieldUiCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, bundle.marker), "every indexed file is ready after publication")
  Assert.isFalse(FieldUiAssetCache.isReady(cache, bundle.marker .. "-stale"))
end

-- The dialogue frame class must offer at least two visually distinct frame
-- styles with identical strip geometry: the frame index selects artwork
-- (the compiled strip row), never the frame composition. Probes the compiled
-- PNG bytes, not the GPU.
function T.dialogue_frame_styles_are_distinct_artwork_with_identical_geometry(romFs, version)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local frames = bundle.manifest.dialogueFrames
  Assert.isTrue(frames.count >= 2, "the class carries at least two frame styles")

  local strip = bundle.assets[bundle.manifest.assets["hgss.dialogue_frame.tiles"].image]
  local width, height, rgba = PngReader.rgba(strip)

  local function rectPixels(rect)
    Assert.equal(rect.width, 144, "every frame strip row is the full tile run")
    Assert.equal(rect.height, 8)
    Assert.equal(rect.x, 0)
    return rgba:sub(rect.y * width * 4 + 1, (rect.y + 8) * width * 4)
  end

  -- Each frame strip row is its own 18-tile run; rows are distinct artwork.
  local distinctRows = {}
  for frame = 0, frames.count - 1 do
    local rect = frames.frameTiles[frame]
    local row = rectPixels(rect)
    Assert.isNil(distinctRows[row], "frame " .. frame .. " must not duplicate an earlier frame row")
    distinctRows[row] = frame
  end

  -- Frame 0 vs frame 1 render different artwork: the two strip rows are not
  -- the same pixels (a frame-option change must alter the artwork).
  local row0 = rectPixels(frames.frameTiles[0])
  local row1 = rectPixels(frames.frameTiles[1])
  Assert.isTrue(row0 ~= row1, "frame 0 and frame 1 render different artwork")

  -- The corner tiles are transparent-corners artwork, so also pin a known
  -- opaque difference: frame 0 tile 6 is blue (107,222,255) and frame 1
  -- tile 6 is cream (255,239,222) at the same strip coordinate.
  local tile6X = 6 * 8 + 4
  local r0, g0, b0, a0 = PngReader.pixel(rgba, width, tile6X, frames.frameTiles[0].y)
  local r1, g1, b1, a1 = PngReader.pixel(rgba, width, tile6X, frames.frameTiles[1].y)
  Assert.equal(a0, 255, "frame 0 tile 6 is opaque")
  Assert.equal(a1, 255, "frame 1 tile 6 is opaque")
  Assert.isTrue(r0 ~= r1 or g0 ~= g1 or b0 ~= b1, "frame 0 and frame 1 tile 6 colors differ")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
