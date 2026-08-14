-- ROM-conformance facts for the generated field-UI class: the real private
-- dump compiles the bundle (frames, signposts, Start Menu, Trainer Card,
-- and the three Start Menu effects), every indexed file passes
-- FieldUiAssetCache.isReady, and the compile is deterministic. Asserts only
-- non-copyright structural facts.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
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
  Assert.equal(bundle.manifest.sounds["start_menu.open"].sampleRate, 22050)
  Assert.equal(bundle.manifest.sounds["start_menu.select"].sampleRate, 22077)
  Assert.equal(bundle.manifest.sounds["start_menu.cancel"].sampleRate, 22077)

  -- Recompiling is deterministic and the published class is fully ready.
  local second = assert(FieldUiCompiler.compile(romFs))
  Assert.equal(second.marker, bundle.marker)
  FieldUiCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, bundle.marker), "every indexed file is ready after publication")
  Assert.isFalse(FieldUiAssetCache.isReady(cache, bundle.marker .. "-stale"))
end

return require("tests.rom.support.RomSuite").fromFacts(T)
