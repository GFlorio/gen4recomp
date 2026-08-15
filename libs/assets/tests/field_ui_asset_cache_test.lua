-- FieldUiAssetCache contract: strict paths, the FORMAT:romSha1:depHash
-- marker written last, isReady semantics (marker + manifest + every indexed
-- file), and strict rejection of malformed generated metadata (missing
-- arrays, unknown values, non-finite/negative/out-of-atlas rectangles).

local Assert = require("tests.support.Assert")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function validManifest()
  local frameTiles = {}
  for frame = 0, 19 do
    frameTiles[frame] = { x = 0, y = 0, width = 160, height = 8 }
  end
  local slots = {}
  for id = 1, 10 do
    slots[id] = { x = (id % 2 == 1 and 0 or 128), y = math.floor((id - 1) / 2) * 38, width = 128, height = 38 }
  end
  return {
    schema = FieldUiAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = {
      ["hgss.dialogue_frame.tiles"] = {
        image = "assets/generated/field/ui/dialogue-frame-tiles.png",
        width = 160,
        height = 8,
      },
      ["hgss.signpost.tiles"] = { image = "assets/generated/field/ui/signpost-tiles.png", width = 160, height = 8 },
      ["hgss.signpost.wayfinding"] = {
        image = "assets/generated/field/ui/wayfinding-tiles.png",
        width = 208,
        height = 16,
      },
      ["hgss.start_menu.background"] = { image = "assets/generated/field/ui/start-menu.png", width = 256, height = 192 },
      ["hgss.start_menu.cursor"] = {
        image = "assets/generated/field/ui/start-menu-cursor.png",
        width = 32,
        height = 32,
      },
      ["hgss.trainer_card.front"] = { image = "assets/generated/field/ui/trainer-card.png", width = 256, height = 192 },
    },
    dialogueFrames = {
      count = 20,
      frameTiles = frameTiles,
    },
    signposts = {
      frame = { tiles = { x = 0, y = 0, width = 160, height = 8 } },
      types = {
        [0] = {
          sourceType = 0,
          wayfinding = {
            [0] = { x = 0, y = 0, width = 208, height = 8 },
            [1] = { x = 0, y = 8, width = 208, height = 8 },
          },
        },
        [2] = { sourceType = 2 },
      },
    },
    startMenu = {
      background = { x = 0, y = 0, width = 256, height = 192 },
      cursor = { frames = { { x = 0, y = 0, width = 32, height = 32, duration = 3 } } },
      slots = slots,
    },
    trainerCard = { front = { x = 0, y = 0, width = 256, height = 192 } },
  }
end

local function publishedCache(manifest)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest or validManifest())
  cache:write(FieldUiAssetCache.markerPath(), FieldUiAssetCache.marker("rom-sha", "dep-hash"))
  for _, entry in pairs((manifest or validManifest()).assets) do
    cache:write(entry.image, "png")
  end
  return cache
end

function T.contract_constants_flow_from_the_contract_owner()
  Assert.equal(FieldUiAssetCache.FORMAT, DerivedAssetContract.fieldUi.cacheFormat)
  Assert.equal(FieldUiAssetCache.SCHEMA, DerivedAssetContract.fieldUi.schema)
  Assert.equal(FieldUiAssetCache.marker("abc", "def"), "field-ui-cache-v1:abc:def")
end

function T.ready_requires_marker_manifest_and_every_indexed_file()
  local cache = publishedCache()
  Assert.isTrue(FieldUiAssetCache.isReady(cache, FieldUiAssetCache.marker("rom-sha", "dep-hash")))
  Assert.isFalse(
    FieldUiAssetCache.isReady(cache, FieldUiAssetCache.marker("rom-sha", "stale")),
    "marker must match exactly"
  )
  cache:remove(FieldUiAssetCache.markerPath())
  Assert.isFalse(FieldUiAssetCache.isReady(cache, FieldUiAssetCache.marker("rom-sha", "dep-hash")))
  local cache2 = publishedCache()
  cache2:remove("assets/generated/field/ui/start-menu.png")
  Assert.isFalse(
    FieldUiAssetCache.isReady(cache2, FieldUiAssetCache.marker("rom-sha", "dep-hash")),
    "a missing indexed file is not ready"
  )
end

local function reject(mutate, code)
  local manifest = validManifest()
  mutate(manifest)
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok)
  Assert.equal(assert(err).code, code)
end

function T.missing_or_unknown_schema_and_reference_are_rejected()
  reject(function(m)
    m.schema = "g4-field-ui-v0"
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.reference = { width = 320, height = 240 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.assets_must_be_non_empty_with_dimensions()
  reject(function(m)
    m.assets = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.assets["hgss.start_menu.background"].width = -1
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.rectangles_outside_their_atlas_are_rejected()
  reject(function(m)
    m.startMenu.background = { x = 0, y = 0, width = 257, height = 192 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.background.x = 1.5
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[2] = { sourceType = "two" }
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.missing_sections_are_rejected()
  reject(function(m)
    m.dialogueFrames = nil
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu = nil
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- The start menu surface contract: at least one cursor frame, the dense
-- 1..10 slot grid (the touch surface the producer hard-codes), and every
-- slot rect inside the background atlas.
function T.start_menu_surface_validation_is_strict()
  reject(function(m)
    m.startMenu.cursor.frames = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[1] = nil
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[3] = nil
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[11] = { x = 0, y = 0, width = 128, height = 38 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[5] = { x = 200, y = 0, width = 128, height = 38 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots = { [0] = { x = 0, y = 0, width = 128, height = 38 } }
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- Signpost type entries must be keyed by their own sourceType, and every
-- map-specific wayfinding record is a validated atlas rectangle.
function T.signpost_type_and_wayfinding_validation_is_strict()
  reject(function(m)
    m.signposts.types[2].sourceType = 3
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[7] = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[2].wayfinding = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].wayfinding[-1] = { x = 0, y = 0, width = 208, height = 8 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].wayfinding[1] = { x = 0, y = 0, width = 209, height = 8 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

return { tests = T }
