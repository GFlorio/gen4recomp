-- FieldSaveStore tests verify version-scoped transactional publication and
-- rejection of malformed persisted data with an in-memory filesystem.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function record(versionId, overrides)
  local value = {
    schema = FieldSave.SCHEMA, versionId = versionId, mapId = 60,
    fieldX = 684, fieldZ = 393, worldY = 0, surfaceId = 0,
    terrainDependencyHash = "terrain", facing = "south",
    avatar = "hero", scenario = "pre-script-demo-v1",
    events = { flags = {}, vars = {} },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

function T.atomic_save_publishes_without_leaving_temporary_file()
  local backend = FakeCache.new()
  local store = FieldSaveStore.new(CacheFs.forVersion("heartgold", backend))
  store:save(record("heartgold"))
  Assert.deepEqual(assert(store:load()), record("heartgold"))
  Assert.isNil(backend.files["heartgold/save/field-session-v1.lua.tmp"])
end

function T.imported_versions_have_independent_saves()
  local backend = FakeCache.new()
  local hg = FieldSaveStore.new(CacheFs.forVersion("heartgold", backend))
  local ss = FieldSaveStore.new(CacheFs.forVersion("soulsilver", backend))
  hg:save(record("heartgold"))
  ss:save(record("soulsilver"))
  Assert.equal(assert(hg:load()).versionId, "heartgold")
  Assert.equal(assert(ss:load()).versionId, "soulsilver")
end

function T.load_rejects_unknown_schemas()
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  cacheFs:writeLua(FieldSave.PATH, {
    schema = "g4-field-save-v0", versionId = "heartgold", mapId = 60,
    fieldX = 684, fieldZ = 393, worldY = 0, surfaceId = 0,
    terrainDependencyHash = "terrain", facing = "south",
  })
  local store = FieldSaveStore.new(cacheFs)
  local loaded, loadErr = store:load()
  Assert.isNil(loaded)
  Assert.isTrue(loadErr and loadErr.code == "FIELD_SAVE_SCHEMA_NEWER",
    "expected FIELD_SAVE_SCHEMA_NEWER, got " .. tostring(loadErr))
end

function T.save_validates_the_compiled_avatar_set()
  local backend = FakeCache.new()
  local store = FieldSaveStore.new(CacheFs.forVersion("heartgold", backend),
    { avatars = { hero = true, heroine = true } })
  local err = Assert.throws(function()
    store:save(record("heartgold", { avatar = "rival" }))
  end)
  Assert.isTrue(err and err.code == "FIELD_SAVE_AVATAR_INVALID",
    "expected FIELD_SAVE_AVATAR_INVALID, got " .. tostring(err))
  Assert.isNil(store:load(), "the rejected save must not be published")
  store:save(record("heartgold", { avatar = "heroine" }))
  Assert.equal(assert(store:load()).avatar, "heroine")
end

function T.reset_removes_stable_and_temporary_files()
  local backend = FakeCache.new()
  local store = FieldSaveStore.new(CacheFs.forVersion("heartgold", backend))
  store:save(record("heartgold"))
  backend.files["heartgold/save/field-session-v1.lua.tmp"] = "partial"
  store:reset()
  Assert.isNil(store:load())
  Assert.isNil(backend.files["heartgold/save/field-session-v1.lua.tmp"])
end

return T
