-- FieldSaveStore tests verify version-scoped transactional publication and
-- rejection of malformed persisted data with an in-memory filesystem. The
-- store is rooted in the persistent user-data namespace (SaveFs), never in the
-- disposable version cache. Loading is the complete validation boundary: a
-- record whose wired scripts bucket fails deep validation is rejected as a
-- whole.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local SaveFs = require("libs.rom.src.SaveFs")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local SAVE_TEMP = "saves/heartgold/field-session-v1.lua.tmp"

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
    events = { flags = {}, vars = {} },
    auxiliaryUi = { requested = "shown", state = "shown" },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

function T.atomic_save_publishes_without_leaving_temporary_file()
  local backend = FakeCache.new()
  local store = FieldSaveStore.new(SaveFs.forVersion("heartgold", backend))
  store:save(record("heartgold"))
  Assert.deepEqual(assert(store:load()), record("heartgold"))
  Assert.isNil(backend.files[SAVE_TEMP])
  Assert.isNil(backend.files["heartgold/save/field-session-v1.lua"], "saves must not live in the cache root")
end

function T.imported_versions_have_independent_saves()
  local backend = FakeCache.new()
  local hg = FieldSaveStore.new(SaveFs.forVersion("heartgold", backend))
  local ss = FieldSaveStore.new(SaveFs.forVersion("soulsilver", backend))
  hg:save(record("heartgold"))
  ss:save(record("soulsilver"))
  Assert.equal(assert(hg:load()).versionId, "heartgold")
  Assert.equal(assert(ss:load()).versionId, "soulsilver")
end

function T.load_rejects_unknown_schemas()
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
  local store = FieldSaveStore.new(saveFs)
  local loaded, loadErr = store:load()
  Assert.isNil(loaded)
  Assert.isTrue(
    loadErr and loadErr.code == "FIELD_SAVE_SCHEMA_NEWER",
    "expected FIELD_SAVE_SCHEMA_NEWER, got " .. tostring(loadErr)
  )
end

function T.save_validates_the_compiled_avatar_set()
  local backend = FakeCache.new()
  local store =
    FieldSaveStore.new(SaveFs.forVersion("heartgold", backend), { avatars = { hero = true, heroine = true } })
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
  local store = FieldSaveStore.new(SaveFs.forVersion("heartgold", backend))
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
  local store = FieldSaveStore.new(SaveFs.forVersion("heartgold", backend))
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

-- The store load is the complete validation boundary: a scripts bucket that
-- passes the envelope but carries a malformed environment record must be
-- rejected as a whole before any live state is constructed.
function T.load_rejects_a_deeply_malformed_scripts_bucket()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local store = FieldSaveStore.new(saveFs, {
    scriptsValidate = function(bucket)
      return ScriptSave.validate(bucket, {})
    end,
  })
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
  local loaded, loadErr = store:load()
  Assert.isNil(loaded)
  Assert.isTrue(
    loadErr and loadErr.code == "FIELD_SAVE_SCRIPTS_INVALID",
    "expected FIELD_SAVE_SCRIPTS_INVALID, got " .. tostring(loadErr and loadErr.code or loadErr)
  )
end

return T
