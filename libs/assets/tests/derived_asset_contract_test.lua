-- DerivedAssetContract is the single consumer-visible identity of the derived
-- assets crossing the romdump boundary. These tests pin its shape and exact
-- values, and assert every consuming cache module exposes the same constants,
-- so a format/schema change cannot be made in one place and missed in another.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioSample = require("libs.assets.src.AudioSample")
local AudioSequence = require("libs.assets.src.AudioSequence")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldWeatherCache = require("libs.assets.src.FieldWeatherCache")
local NewGameInitCache = require("libs.assets.src.NewGameInitCache")
local FieldEmoteAssetCache = require("libs.assets.src.FieldEmoteAssetCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")

local T = {}

function T.contract_pins_the_current_asset_identities()
  -- The audio contracts moved to explicit class schemas while the global
  -- revision identifies the current shared generated-asset contracts. The
  -- sequence initial-volume domain is the current NNS table domain.
  Assert.deepEqual(DerivedAssetContract, {
    revision = 10,
    map = {
      cacheFormat = "map-cache-v7",
      sceneSchema = "g4-map-scene-v9",
      terrainSchema = "g4-terrain-surfaces-v1",
      collisionVersion = 1,
    },
    fieldCells = {
      cacheFormat = "field-cell-cache-v2",
      indexSchema = "g4-field-cell-index-v2",
      cellSchema = "g4-field-cell-v2",
    },
    fieldActors = {
      cacheFormat = "field-actor-cache-v2",
      schema = "g4-field-actor-v3",
      indexSchema = "g4-field-actor-index-v2",
    },
    fieldCamera = {
      cacheFormat = "g4-field-camera-cache-v1",
      schema = "g4-field-camera-profiles-v1",
    },
    fieldMapData = {
      cacheFormat = "g4-field-map-cache-v1",
      fieldSchema = "g4-field-map-v9",
    },
    messages = {
      cacheFormat = "field-message-cache-v3",
      schema = "g4-field-message-bank-v1",
      indexSchema = "g4-field-message-index-v1",
      provenanceSchema = "g4-field-message-provenance-v1",
    },
    font = {
      cacheFormat = "field-font-cache-v3",
      schema = "g4-field-font-v3",
    },
    scripts = {
      cacheFormat = "script-cache-v2",
      indexSchema = "g4-script-index-v1",
      provenanceSchema = "g4-script-provenance-v1",
    },
    fieldWeather = {
      cacheFormat = "field-weather-cache-v1",
      schema = "g4-field-weather-v1",
    },
    newGameInit = {
      cacheFormat = "g4-new-game-init-cache-v1",
      schema = "g4-new-game-init-v2",
    },
    fieldEffects = {
      cacheFormat = "field-effect-cache-v6",
      indexSchema = "g4-field-effect-index-v1",
    },
    fieldEmotes = {
      cacheFormat = "field-emotes-cache-v2",
      schema = "g4-field-emote-v1",
    },
    fieldUi = {
      cacheFormat = "field-ui-cache-v1",
      schema = "g4-field-ui-v7",
    },
    intro = {
      cacheFormat = "intro-cache-v9",
      schema = "g4-intro-assets-v9",
      provenanceSchema = "g4-intro-provenance-v1",
    },
    audio = {
      cacheFormat = "g4-audio-cache-v1",
      -- The sequence vocabulary and initial-volume domain are strict current
      -- contracts; earlier sequence assets are stale.
      indexSchema = "g4-audio-index-v5",
      sequenceSchema = "g4-audio-sequence-v9",
      bankSchema = "g4-audio-bank-v5",
      sampleSchema = "g4-audio-sample-v4",
      provenanceSchema = "g4-audio-provenance-v1",
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
  Assert.equal(AudioCache.FORMAT, DerivedAssetContract.audio.cacheFormat)
  Assert.equal(AudioCache.INDEX_SCHEMA, DerivedAssetContract.audio.indexSchema)
  Assert.equal(AudioCache.SEQUENCE_SCHEMA, DerivedAssetContract.audio.sequenceSchema)
  Assert.equal(AudioCache.BANK_SCHEMA, DerivedAssetContract.audio.bankSchema)
  Assert.equal(AudioCache.SAMPLE_SCHEMA, DerivedAssetContract.audio.sampleSchema)
  Assert.equal(AudioCache.PROVENANCE_SCHEMA, DerivedAssetContract.audio.provenanceSchema)
  Assert.equal(AudioSequence.SCHEMA, DerivedAssetContract.audio.sequenceSchema)
  Assert.equal(AudioBank.SCHEMA, DerivedAssetContract.audio.bankSchema)
  Assert.equal(AudioSample.SCHEMA, DerivedAssetContract.audio.sampleSchema)
  Assert.equal(FieldWeatherCache.FORMAT, DerivedAssetContract.fieldWeather.cacheFormat)
  Assert.equal(FieldWeatherCache.SCHEMA, DerivedAssetContract.fieldWeather.schema)
  Assert.equal(NewGameInitCache.FORMAT, DerivedAssetContract.newGameInit.cacheFormat)
  Assert.equal(NewGameInitCache.SCHEMA, DerivedAssetContract.newGameInit.schema)
  Assert.equal(FieldEmoteAssetCache.FORMAT, DerivedAssetContract.fieldEmotes.cacheFormat)
  Assert.equal(FieldEmoteAssetCache.SCHEMA, DerivedAssetContract.fieldEmotes.schema)
  Assert.equal(FieldEffectAssetCache.FORMAT, DerivedAssetContract.fieldEffects.cacheFormat)
end

return { tests = T }
