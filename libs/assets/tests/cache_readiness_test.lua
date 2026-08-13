-- Strict generated-cache readiness: a completion marker plus a malformed
-- current index/descriptor must never read as ready. Required arrays must be
-- arrays, identity fields must match, and referenced artifacts must be present
-- and loadable. Missing schema fields must not default to empty collections.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local CollisionFixture = require("tests.support.CollisionFixture")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")

local T = {}

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

-- Field-actor index and visuals

local function writeActorIndex(c, spriteIds)
  c:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = spriteIds,
    runtime = {
      avatars = { { id = "hero", spriteId = 0 } },
      variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
    },
  })
  c:write(FieldActorCache.markerPath(), "m")
end

local function writeActorVisual(c, spriteId)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = { kind = "atlas", image = FieldActorCache.atlasPath(spriteId) },
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

function T.actor_index_missing_sprite_ids_is_not_ready()
  local c = cache()
  c:writeLua(FieldActorCache.indexPath(), { schema = FieldActorCache.INDEX_SCHEMA })
  c:write(FieldActorCache.markerPath(), "m")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "spriteIds is required by the current schema")
end

function T.actor_index_with_non_array_sprite_ids_is_not_ready()
  local c = cache()
  writeActorIndex(c, { named = 1 })
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "a hash table is not a spriteIds array")
end

function T.actor_index_without_runtime_config_is_not_ready()
  local c = cache()
  c:writeLua(FieldActorCache.indexPath(), { schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  c:write(FieldActorCache.markerPath(), "m")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "the runtime avatar/sprite config is required by the schema")
end

function T.actor_visual_with_wrong_schema_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), { schema = "g4-other-v1", spriteId = 0 })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "indexed visual must carry the expected schema")
end

function T.actor_visual_with_wrong_identity_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), { schema = FieldActorCache.SCHEMA, spriteId = 7 })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "visual file identity must match its index entry")
end

function T.actor_valid_artifact_is_ready()
  local c = cache()
  writeActorIndex(c, { 0, 29 })
  writeActorVisual(c, 0)
  writeActorVisual(c, 29)
  Assert.isTrue(FieldActorCache.isReady(c, "m"))
end

-- Field-message index and banks

local function writeMessageIndex(c, bankIds)
  c:writeLua(FieldMessageCache.indexPath(), {
    schema = FieldMessageCache.INDEX_SCHEMA,
    bankIds = bankIds,
  })
  c:write(FieldMessageCache.markerPath(), "m")
end

function T.message_index_missing_bank_ids_is_not_ready()
  local c = cache()
  c:writeLua(FieldMessageCache.indexPath(), { schema = FieldMessageCache.INDEX_SCHEMA })
  c:write(FieldMessageCache.markerPath(), "m")
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "bankIds is required by the current schema")
end

function T.message_index_with_non_array_bank_ids_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { named = 1 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "a hash table is not a bankIds array")
end

function T.message_bank_with_wrong_identity_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = FieldMessageCache.SCHEMA, bankId = 543 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "bank file identity must match its index entry")
end

function T.message_bank_with_wrong_schema_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = "g4-other-v1", bankId = 542 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "bank file must carry the expected schema")
end

function T.message_valid_artifact_is_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = FieldMessageCache.SCHEMA, bankId = 542 })
  Assert.isTrue(FieldMessageCache.isReady(c, "m"))
end

-- Map scene, model descriptors, and neighbor cells

local function mapScene(mapId)
  return {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = mapId,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {},
  }
end

local function writeMapScene(c, mapId, scene)
  c:writeLua(MapAssetCache.mapDir(mapId) .. "/scene.lua", scene or mapScene(mapId))
  c:writeLua(MapAssetCache.terrainPath(mapId), { schema = "g4-terrain-surfaces-v1" })
  c:write(MapAssetCache.mapDir(mapId) .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.collisionPath(mapId), CollisionFixture.asset(32, 32))
  c:write(MapAssetCache.mapDir(mapId) .. "/complete", "m")
end

function T.map_scene_missing_materials_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.materials = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "materials is required by the current schema")
end

function T.map_scene_with_non_array_materials_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.materials = { diffuse = 1 }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "a hash table is not a materials array")
end

function T.map_scene_missing_map_batches_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.mapBatches = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "mapBatches is required by the current schema")
end

function T.map_scene_missing_building_instances_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.buildingInstances = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "buildingInstances is required by the current schema")
end

function T.map_scene_missing_neighbors_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.neighbors = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "neighbors is required by the current schema")
end

function T.map_scene_with_non_array_neighbors_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.neighbors = "nope"
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "neighbors must be an array, never a bare value")
end

function T.map_scene_with_wrong_schema_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.schema = "g4-map-scene-v2"
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "scene identity must carry the expected schema")
end

function T.map_scene_with_wrong_map_id_is_not_ready()
  local c = cache()
  local scene = mapScene(99)
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "scene identity must match the probed map")
end

function T.map_batch_without_geometry_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.mapBatches = { { material = 0 } }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "every batch must reference a geometry path")
end

function T.map_scene_with_non_table_batch_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.mapBatches = { 5 }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "a non-table batch element is malformed, not a readable scene")
end

function T.map_neighbor_cell_without_batches_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.neighbors = { { offsetTilesX = 0, offsetTilesZ = 32, materials = {} } }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "neighbor cells must carry batches and materials arrays")
end

function T.map_model_descriptor_without_batches_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.buildingInstances = { { modelKey = "indoor:1:abc" } }
  writeMapScene(c, 61, scene)
  c:writeLua(MapAssetCache.modelPath("indoor:1:abc"), { materials = {} })
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "model descriptor batches is required")
end

function T.map_model_descriptor_without_materials_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.buildingInstances = { { modelKey = "indoor:1:abc" } }
  writeMapScene(c, 61, scene)
  c:writeLua(MapAssetCache.modelPath("indoor:1:abc"), { batches = {} })
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "model descriptor materials is required")
end

function T.map_valid_artifact_is_ready()
  local c = cache()
  writeMapScene(c, 61)
  Assert.isTrue(MapAssetCache.isReady(c, 61, "m"))
end

-- Field-map record collections

local function writeFieldRecord(c, mapId, events)
  c:writeLua(FieldMapDataCache.fieldPath(mapId), {
    schema = "g4-field-map-v1",
    mapId = mapId,
    mapSymbol = "test",
    events = events,
  })
  c:writeLua(FieldMapDataCache.dependenciesPath(mapId), { cacheFormat = FieldMapDataCache.FORMAT })
  c:write(FieldMapDataCache.markerPath(mapId), "m")
end

function T.field_data_missing_events_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, nil)
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "events is required by the current schema")
end

function T.field_data_with_partial_events_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {} })
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "all four event collections are required")
end

function T.field_data_with_non_array_event_collection_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = "x", coordinates = {} })
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "each event collection must be an array")
end

function T.field_data_valid_artifact_is_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = {}, coordinates = {} })
  Assert.isTrue(FieldMapDataCache.isReady(c, 60, "m"))
end

-- Script index and emitted resources

local function writeScriptIndex(c, resources)
  c:writeLua(ScriptCache.indexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    resources = resources,
  })
  c:write(ScriptCache.markerPath(), "m")
end

function T.script_index_missing_resources_is_not_ready()
  local c = cache()
  c:writeLua(ScriptCache.indexPath(), { schema = ScriptCache.INDEX_SCHEMA })
  c:write(ScriptCache.markerPath(), "m")
  Assert.isFalse(ScriptCache.isReady(c, "m"), "resources is required by the current schema")
end

function T.script_index_with_non_array_resources_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { named = 1 })
  Assert.isFalse(ScriptCache.isReady(c, "m"), "a hash table is not a resources array")
end

function T.script_resource_with_mismatched_id_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(ScriptCache.scriptPath("a.b"), 'return { kind = "field_script", id = "c.d" }\n')
  Assert.isFalse(ScriptCache.isReady(c, "m"), "emitted script identity must match its index entry")
end

function T.script_resource_with_wrong_kind_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(ScriptCache.scriptPath("a.b"), 'return { kind = "other", id = "a.b" }\n')
  Assert.isFalse(ScriptCache.isReady(c, "m"), "emitted script must be a field_script resource")
end

function T.script_resource_that_does_not_parse_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(ScriptCache.scriptPath("a.b"), "not lua at all")
  Assert.isFalse(ScriptCache.isReady(c, "m"), "an unparsable resource cannot be ready")
end

function T.script_valid_artifact_is_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(
    ScriptCache.scriptPath("a.b"),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "a.b", steps = { S.stop() } }\n'
  )
  Assert.isTrue(ScriptCache.isReady(c, "m"))
end

return { tests = T }
