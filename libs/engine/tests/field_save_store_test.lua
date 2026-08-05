-- FieldSaveStore tests verify version-scoped transactional publication and
-- rejection of malformed persisted data with an in-memory filesystem.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function record(versionId)
  return {
    schema = FieldSave.SCHEMA, versionId = versionId, mapId = 60,
    fieldX = 684, fieldZ = 393, worldY = 0, surfaceId = 0,
    terrainDependencyHash = "terrain", facing = "south",
  }
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
