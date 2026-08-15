-- DerivedAssetContract is the single consumer-visible identity of the derived
-- assets crossing the romdump boundary. These tests pin its shape and exact
-- values, and assert every consuming cache module exposes the same constants,
-- so a format/schema change cannot be made in one place and missed in another.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")

local T = {}

function T.contract_pins_the_current_asset_identities()
  Assert.deepEqual(DerivedAssetContract, {
    revision = 2,
    map = {
      cacheFormat = "map-cache-v7",
      sceneSchema = "g4-map-scene-v6",
      terrainSchema = "g4-terrain-surfaces-v1",
      collisionVersion = 1,
    },
    fieldActors = {
      cacheFormat = "field-actor-cache-v1",
      schema = "g4-field-actor-v1",
      indexSchema = "g4-field-actor-index-v1",
    },
    fieldCamera = {
      cacheFormat = "g4-field-camera-cache-v1",
      schema = "g4-field-camera-profiles-v1",
    },
    fieldMapData = {
      cacheFormat = "g4-field-map-cache-v1",
      fieldSchema = "g4-field-map-v1",
    },
    messages = {
      cacheFormat = "field-message-cache-v1",
      schema = "g4-field-message-bank-v1",
      indexSchema = "g4-field-message-index-v1",
      provenanceSchema = "g4-field-message-provenance-v1",
    },
    font = {
      cacheFormat = "field-font-cache-v1",
      schema = "g4-field-font-v1",
    },
    scripts = {
      cacheFormat = "script-cache-v1",
      indexSchema = "g4-script-index-v1",
      provenanceSchema = "g4-script-provenance-v1",
    },
    fieldUi = {
      cacheFormat = "field-ui-cache-v1",
      schema = "g4-field-ui-v4",
    },
  })
end

function T.cache_modules_consume_the_contract_constants()
  Assert.equal(MapAssetCache.FORMAT, DerivedAssetContract.map.cacheFormat)
  Assert.equal(MapAssetCache.SCENE_SCHEMA, DerivedAssetContract.map.sceneSchema)
  Assert.equal(MapAssetCache.TERRAIN_SCHEMA, DerivedAssetContract.map.terrainSchema)
  Assert.equal(CollisionGridAsset.VERSION, DerivedAssetContract.map.collisionVersion)
  Assert.equal(FieldActorCache.FORMAT, DerivedAssetContract.fieldActors.cacheFormat)
  Assert.equal(FieldActorCache.SCHEMA, DerivedAssetContract.fieldActors.schema)
  Assert.equal(FieldActorCache.INDEX_SCHEMA, DerivedAssetContract.fieldActors.indexSchema)
  Assert.equal(FieldCameraCache.FORMAT, DerivedAssetContract.fieldCamera.cacheFormat)
  Assert.equal(FieldCameraCache.SCHEMA, DerivedAssetContract.fieldCamera.schema)
  Assert.equal(FieldMapDataCache.FORMAT, DerivedAssetContract.fieldMapData.cacheFormat)
  Assert.equal(FieldMapDataCache.FIELD_SCHEMA, DerivedAssetContract.fieldMapData.fieldSchema)
  Assert.equal(FieldMessageCache.FORMAT, DerivedAssetContract.messages.cacheFormat)
  Assert.equal(FieldMessageCache.SCHEMA, DerivedAssetContract.messages.schema)
  Assert.equal(FieldMessageCache.INDEX_SCHEMA, DerivedAssetContract.messages.indexSchema)
  Assert.equal(FieldMessageCache.PROVENANCE_SCHEMA, DerivedAssetContract.messages.provenanceSchema)
  Assert.equal(FieldFontCache.FORMAT, DerivedAssetContract.font.cacheFormat)
  Assert.equal(FieldFontCache.SCHEMA, DerivedAssetContract.font.schema)
  Assert.equal(ScriptCache.FORMAT, DerivedAssetContract.scripts.cacheFormat)
  Assert.equal(ScriptCache.INDEX_SCHEMA, DerivedAssetContract.scripts.indexSchema)
  Assert.equal(ScriptCache.PROVENANCE_SCHEMA, DerivedAssetContract.scripts.provenanceSchema)
  Assert.equal(FieldUiAssetCache.FORMAT, DerivedAssetContract.fieldUi.cacheFormat)
  Assert.equal(FieldUiAssetCache.SCHEMA, DerivedAssetContract.fieldUi.schema)
end

return { tests = T }
