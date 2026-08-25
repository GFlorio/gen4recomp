-- FieldSaveStore tests verify version-scoped transactional publication and
-- persistence-only loading with an in-memory filesystem. The store is rooted
-- in the persistent user-data namespace (SaveFs), never in the disposable
-- version cache. Loading returns the deserialized record unchanged; resume
-- validation/canonicalization belongs to the FieldSave.restore boundary, and
-- save still validates and persists the canonical record.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local FakeCache = require("tests.support.FakeCache")
local PlayerDataContext = require("tests.support.PlayerDataContext")

local T = {}

---@class FieldSaveStoreFixture
---@field load fun(self: FieldSaveStoreFixture): table?, Errors.Error?
---@field save fun(self: FieldSaveStoreFixture, record: table): boolean
---@field reset fun(self: FieldSaveStoreFixture): boolean

local SAVE_TEMP = "saves/heartgold/" .. FieldSave.PATH .. ".tmp"

-- Restore is the domain validation boundary for deserialized records; the
-- loader must never be reached when validation rejects the record.
local function rejectingLoader()
  return {
    load = function()
      error("restore must reject the invalid record before loading any map")
    end,
  }
end

-- Mirrors the production resume call: the runtime passes the player-data
-- context it also wired into the store.
---@param overrides table<string, unknown>|nil
---@return table<string, unknown>
local function restoreOpts(overrides)
  local value = { playerDataContext = PlayerDataContext.new() } ---@type table<string, unknown>
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

-- The store's save boundary requires the player-data validation context
-- (mirroring the runtime composition), so every fixture supplies it.
---@param saveFs SaveFs
---@param opts table<string, unknown>|nil
---@return FieldSaveStoreFixture
local function newStore(saveFs, opts)
  local value = { playerDataContext = PlayerDataContext.new() } ---@type table<string, unknown>
  for key, item in pairs(opts or {}) do
    value[key] = item
  end
  return FieldSaveStore.new(saveFs, value) --[[@as FieldSaveStoreFixture]]
end

local function record(versionId, overrides)
  local value = {
    schema = FieldSave.SCHEMA,
    versionId = versionId,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain",
    facing = "south",
    avatar = "hero",
    scenario = "pre-script-demo-v1",
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

function T.atomic_save_publishes_without_leaving_temporary_file()
  local backend = FakeCache.new()
  local store = newStore(SaveFs.forVersion("heartgold", backend))
  store:save(record("heartgold"))
  Assert.deepEqual(assert(store:load()), record("heartgold"))
  Assert.isNil(backend.files[SAVE_TEMP])
  Assert.isNil(backend.files["heartgold/save/" .. FieldSave.PATH], "saves must not live in the cache root")
end

-- The store load is persistence only: the deserialized record is returned
-- unchanged, so a record carrying uncanonical player-data keys survives the
-- load exactly as written. Validation and canonicalization are the restore
-- boundary's job, never the load path's.
function T.load_returns_the_deserialized_record_unchanged()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local store = newStore(saveFs)
  local value = record("heartgold")
  value.playerData.profile.transientThing = 123
  value.playerData.options.futureThing = true
  value.playerData.extraTopLevel = true
  saveFs:writeLua(FieldSave.PATH, value)
  local loaded, loadErr = store:load()
  Assert.isNil(loadErr, "persistence load must not validate; got " .. tostring(loadErr))
  loaded = assert(loaded, "load must return the deserialized record")
  Assert.equal(loaded.playerData.profile.transientThing, 123, "the raw bucket must survive load unchanged")
  Assert.equal(loaded.playerData.options.futureThing, true, "the raw bucket must survive load unchanged")
  Assert.equal(loaded.playerData.extraTopLevel, true, "the raw bucket must survive load unchanged")
end

-- Persistence failures stay at the persistence boundary: an absent save and
-- an unparseable save file return the storage/load error unchanged, never a
-- fabricated validation error.
function T.load_returns_storage_errors_unchanged()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local store = newStore(saveFs)
  local missing, missingErr = store:load()
  Assert.isNil(missing)
  Assert.equal(missingErr and missingErr.code, "SAVE_FILE_MISSING")
  saveFs:write(FieldSave.PATH, "this is not lua")
  local corrupt, corruptErr = store:load()
  Assert.isNil(corrupt)
  Assert.equal(corruptErr and corruptErr.code, "SAVE_LUA_PARSE_FAILED")
end

function T.imported_versions_have_independent_saves()
  local backend = FakeCache.new()
  local hg = newStore(SaveFs.forVersion("heartgold", backend))
  local ss = newStore(SaveFs.forVersion("soulsilver", backend))
  hg:save(record("heartgold"))
  ss:save(record("soulsilver"))
  Assert.equal(assert(hg:load()).versionId, "heartgold")
  Assert.equal(assert(ss:load()).versionId, "soulsilver")
end

-- The store load returns the raw record for any present file; schema
-- rejection belongs to the restore boundary.
function T.load_is_persistence_only_and_restore_rejects_unknown_schemas()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  saveFs:writeLua(FieldSave.PATH, {
    schema = "g4-field-save-v0",
    versionId = "heartgold",
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain",
    facing = "south",
  })
  local store = newStore(saveFs)
  local loaded, loadErr = store:load()
  Assert.isNil(loadErr, "persistence load must not validate; got " .. tostring(loadErr))
  local _, restoreErr = FieldSave.restore(assert(loaded), rejectingLoader(), "heartgold", restoreOpts())
  Assert.equal(
    restoreErr and restoreErr.code,
    "FIELD_SAVE_SCHEMA_UNSUPPORTED",
    "the unsupported schema must be rejected at restore"
  )
end

-- Restore is the save validation boundary: a persisted world bucket whose rng
-- state is malformed loads raw and is rejected as a whole by restore, never
-- accepted and left for a later runtime stage to fail on.
function T.a_malformed_world_bucket_reaches_restore_and_is_rejected()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local value = record("heartgold")
  value.world.rng = {}
  saveFs:writeLua(FieldSave.PATH, value)
  local store = newStore(saveFs)
  local loaded = assert(store:load(), "persistence load must return the raw record")
  local _, restoreErr = FieldSave.restore(loaded, rejectingLoader(), "heartgold", restoreOpts())
  Assert.equal(restoreErr and restoreErr.code, "FIELD_SAVE_WORLD_INVALID")
end

function T.save_validates_the_compiled_avatar_set()
  local backend = FakeCache.new()
  local store = newStore(SaveFs.forVersion("heartgold", backend), { avatars = { hero = true, heroine = true } })
  local err = Assert.throws(function()
    store:save(record("heartgold", { avatar = "rival" }))
  end)
  Assert.isTrue(
    err and err.code == "FIELD_SAVE_AVATAR_INVALID",
    "expected FIELD_SAVE_AVATAR_INVALID, got " .. tostring(err)
  )
  Assert.isNil(store:load(), "the rejected save must not be published")
  store:save(record("heartgold", { avatar = "heroine" }))
  Assert.equal(assert(store:load()).avatar, "heroine")
end

function T.reset_removes_stable_and_temporary_files()
  local backend = FakeCache.new()
  local store = newStore(SaveFs.forVersion("heartgold", backend))
  store:save(record("heartgold"))
  backend.files[SAVE_TEMP] = "partial"
  store:reset()
  Assert.isNil(store:load())
  Assert.isNil(backend.files[SAVE_TEMP])
end

-- A save reset operates only on the user-data namespace: the disposable
-- version cache must remain byte-identical.
function T.reset_does_not_touch_the_cache()
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  cacheFs:write("rom-dump.complete", "MARKER")
  cacheFs:write("romfs/a/0/0/2", "DATA")
  local store = newStore(SaveFs.forVersion("heartgold", backend))
  store:save(record("heartgold"))
  store:reset()
  Assert.isNil(store:load())
  Assert.equal(backend.files["heartgold/rom-dump.complete"], "MARKER")
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "DATA")
end

-- The store is a save owner: a disposable version-cache root must be rejected
-- so a wiring mistake cannot silently move saves back under the deletion root.
function T.store_rejects_a_disposable_cache_root()
  local err = Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- intentional: the store must reject a cache root
    FieldSaveStore.new(CacheFs.forVersion("heartgold", FakeCache.new()))
  end)
  Assert.isTrue(tostring(err):find("SaveFs"), "expected a SaveFs-required assertion, got: " .. tostring(err))
end

-- Restore is the save validation boundary: a scripts bucket that passes the
-- envelope but carries a malformed environment record loads raw and is
-- rejected as a whole by restore before any live state is constructed.
function T.a_deeply_malformed_scripts_bucket_reaches_restore_and_is_rejected()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local scriptsValidate = function(bucket)
    return ScriptSave.validate(bucket, {})
  end
  local store = newStore(saveFs)
  local value = record("heartgold")
  value.scripts = {
    schema = ScriptSave.SCHEMA_NAME,
    nextEnvironmentId = 1,
    nextInstanceId = 1,
    nextTaskId = 1,
    environments = { { environmentId = "e1", mode = "banana", createdAtInTicks = 0 } },
    instances = {},
    tasks = {},
  }
  saveFs:writeLua(FieldSave.PATH, value)
  local loaded = assert(store:load(), "persistence load must return the raw record")
  local _, restoreErr =
    FieldSave.restore(loaded, rejectingLoader(), "heartgold", restoreOpts({ scriptsValidate = scriptsValidate }))
  Assert.equal(restoreErr and restoreErr.code, "FIELD_SAVE_SCRIPTS_INVALID")
end

-- Restore is the save validation boundary: a player-data bucket that fails
-- the injected model validation (here: an over-long name against the
-- generated font context) loads raw and is rejected as a whole by restore,
-- never defaulted.
function T.a_deeply_invalid_player_data_bucket_reaches_restore_and_is_rejected()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local store = newStore(saveFs)
  local value = record("heartgold")
  value.playerData.profile.name = "GOLDGOLD"
  saveFs:writeLua(FieldSave.PATH, value)
  local loaded = assert(store:load(), "persistence load must return the raw record")
  local _, restoreErr = FieldSave.restore(loaded, rejectingLoader(), "heartgold", restoreOpts())
  Assert.equal(restoreErr and restoreErr.code, "FIELD_SAVE_PLAYER_DATA_INVALID")
end

-- Save still validates and persists the canonical record: unknown player-data
-- keys are discarded on disk, so the raw persisted data is canonical even
-- though load never canonicalizes.
function T.save_persists_the_canonical_player_data()
  local backend = FakeCache.new()
  local store = newStore(SaveFs.forVersion("heartgold", backend))
  local value = record("heartgold")
  value.playerData.profile.transientThing = 123
  value.playerData.options.futureThing = true
  value.playerData.extraTopLevel = true
  store:save(value)
  local persisted = assert(store:load())
  Assert.keySet(persisted.playerData, "options,profile", "save must persist the canonical player-data record")
  Assert.keySet(persisted.playerData.profile, "gender,name,trainerId")
  Assert.keySet(persisted.playerData.options, "textFrame,textSpeed")
end

return { tests = T }
