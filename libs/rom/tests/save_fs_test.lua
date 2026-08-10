-- SaveFs tests: the persistent save namespace is version-scoped, confined to
-- its own root, and structurally unreachable by any cache-clearing operation
-- (version-root removal, ROM re-extraction). Cache rebuilding must never be
-- able to delete a save.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local SaveFs = require("libs.rom.src.SaveFs")
local FakeCache = require("tests.support.FakeCache")
local DumpFixture = require("tests.support.DumpFixture")
local RomImporter = require("libs.rom.src.RomImporter")

local T = {}

local SAVE_PATH = "field-session-v1.lua"

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. tostring(err))
end

-- Real-backend construction would write into the production save namespace
-- (saves/<versionId>/) under the g4recomp identity, so every test injects the
-- in-memory fake.
local function save(versionId, backend)
  return SaveFs.forVersion(versionId, backend or FakeCache.new())
end

function T.prefix_roots_at_the_user_data_namespace()
  Assert.equal(save("heartgold"):prefix(), "saves/heartgold/")
  Assert.equal(save("soulsilver"):prefix(), "saves/soulsilver/")
end

function T.scoped_save_root_is_confined_to_the_requested_namespace()
  local scoped = SaveFs.forVersion("heartgold", FakeCache.new(), "acceptance/heartgold/1")
  Assert.equal(scoped:prefix(), "acceptance/heartgold/1/")
end

function T.write_lands_below_the_save_root()
  local backend = FakeCache.new()
  save("heartgold", backend):write(SAVE_PATH, "SAVE-DATA")
  Assert.equal(backend.files["saves/heartgold/" .. SAVE_PATH], "SAVE-DATA")
  Assert.isNil(backend.files["heartgold/" .. SAVE_PATH], "a save must never land in the cache root")
end

function T.read_round_trips_written_bytes()
  local s = save("heartgold")
  s:write(SAVE_PATH, "SAVE-DATA")
  Assert.equal(s:read(SAVE_PATH), "SAVE-DATA")
end

-- One version's saves must never be visible to or cleared by another's.
function T.versions_are_isolated()
  local backend = FakeCache.new()
  local hg = save("heartgold", backend)
  local ss = save("soulsilver", backend)
  hg:write(SAVE_PATH, "HG")
  ss:write(SAVE_PATH, "SS")
  Assert.equal(hg:read(SAVE_PATH), "HG")
  Assert.equal(ss:read(SAVE_PATH), "SS")
  ss:remove(SAVE_PATH)
  Assert.equal(hg:read(SAVE_PATH), "HG")
  Assert.isNil(ss:read(SAVE_PATH))
end

function T.rejects_absolute_paths()
  throwsCode("SAVE_PATH_INVALID", function()
    save("heartgold"):write("/etc/passwd", "x")
  end)
end

function T.rejects_drive_letters()
  throwsCode("SAVE_PATH_INVALID", function()
    save("heartgold"):write("C:/x", "x")
  end)
end

function T.rejects_parent_components()
  throwsCode("SAVE_PATH_INVALID", function()
    save("heartgold"):read("../soulsilver/" .. SAVE_PATH)
  end)
  throwsCode("SAVE_PATH_INVALID", function()
    save("heartgold"):read("a/../../b")
  end)
end

function T.rejects_dot_and_nul_components()
  throwsCode("SAVE_PATH_INVALID", function()
    save("heartgold"):read("a/./b")
  end)
  throwsCode("SAVE_PATH_INVALID", function()
    save("heartgold"):read("a\0b")
  end)
end

function T.lua_round_trip_is_deterministic()
  local s = save("heartgold")
  local value = { schema = "g4-field-save-v1", events = { flags = {}, vars = {} } }
  s:writeLua(SAVE_PATH, value)
  Assert.deepEqual(s:loadLua(SAVE_PATH), value)
end

function T.atomic_replace_moves_a_file_over_its_destination()
  local s = save("heartgold")
  s:write(SAVE_PATH, "old")
  s:write(SAVE_PATH .. ".tmp", "new")
  s:replace(SAVE_PATH .. ".tmp", SAVE_PATH)
  Assert.equal(s:read(SAVE_PATH), "new")
  Assert.isNil(s:read(SAVE_PATH .. ".tmp"))
end

function T.load_lua_missing_returns_nil_err()
  local data, err = save("heartgold"):loadLua("absent.lua")
  Assert.isNil(data)
  Assert.notNil(err)
end

-- The umbrella structural invariant: the disposable version cache root and the
-- persistent save root are sibling namespaces, so wiping a version cache can
-- never delete a save.
function T.removing_the_version_cache_root_cannot_reach_saves()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  saveFs:write(SAVE_PATH, "SAVE-DATA")
  cacheFs:write("rom-dump.complete", "MARKER")
  cacheFs:write("romfs/a/0/0/2", "DATA")
  cacheFs:removeTree("")
  Assert.equal(backend.files["saves/heartgold/" .. SAVE_PATH], "SAVE-DATA")
  Assert.isNil(backend.files["heartgold/rom-dump.complete"])
  Assert.isNil(backend.files["heartgold/romfs/a/0/0/2"])
end

function T.successful_extraction_rebuild_preserves_saves()
  local backend = FakeCache.new()
  SaveFs.forVersion("heartgold", backend):write(SAVE_PATH, "SAVE-DATA")
  local r = DumpFixture.extract({ backend = backend })
  Assert.notNil(r.report, "expected extraction to succeed: " .. tostring(r.err))
  Assert.equal(backend.files["saves/heartgold/" .. SAVE_PATH], "SAVE-DATA")
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", backend)))
end

-- A failed extraction destroys cache state but must leave the save untouched.
function T.failed_extraction_preserves_saves()
  local backend = FakeCache.new()
  SaveFs.forVersion("heartgold", backend):write(SAVE_PATH, "SAVE-DATA")
  local spec = DumpFixture.spec()
  local aZero = spec.tree.dirs[1].dirs[1].dirs -- a/0/{0,1,2,4}
  table.remove(aZero, 4) -- drop a/0/4 (map_matrices)
  local r = DumpFixture.extract({ spec = spec, backend = backend })
  Assert.isNil(r.report, "expected extraction to fail")
  Assert.equal(backend.files["saves/heartgold/" .. SAVE_PATH], "SAVE-DATA")
end

function T.extracting_heartgold_preserves_soulsilver_saves()
  local backend = FakeCache.new()
  SaveFs.forVersion("soulsilver", backend):write(SAVE_PATH, "SS-SAVE")
  local r = DumpFixture.extract({ backend = backend })
  Assert.notNil(r.report)
  Assert.equal(backend.files["saves/soulsilver/" .. SAVE_PATH], "SS-SAVE")
end

-- Mutating save operations must translate a backend-reported failure into
-- a structured save error instead of silently returning true.
function T.write_reports_backend_failure()
  local backend = FakeCache.new()
  ---@diagnostic disable: duplicate-set-field
  backend.write = function()
    return false, "injected write failure"
  end
  throwsCode("SAVE_WRITE_FAILED", function()
    save("heartgold", backend):write(SAVE_PATH, "x")
  end)
end

function T.write_reports_parent_directory_failure()
  local backend = FakeCache.new()
  ---@diagnostic disable: duplicate-set-field
  backend.createDirectory = function()
    return false, "injected mkdir failure"
  end
  throwsCode("SAVE_MKDIR_FAILED", function()
    save("heartgold", backend):write("dir/" .. SAVE_PATH, "x")
  end)
end

function T.remove_reports_backend_failure()
  local backend = FakeCache.new()
  local s = save("heartgold", backend)
  s:write(SAVE_PATH, "x")
  ---@diagnostic disable: duplicate-set-field
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode("SAVE_REMOVE_FAILED", function()
    s:remove(SAVE_PATH)
  end)
end

-- A missing save file is not a failure: reset must be able to run before the
-- first save exists, so absent paths are an explicit no-op.
function T.remove_absent_path_is_a_noop()
  local backend = FakeCache.new()
  ---@diagnostic disable: duplicate-set-field
  backend.remove = function()
    error("backend must not be asked to remove an absent path")
  end
  Assert.isTrue(save("heartgold", backend):remove("absent.lua"))
end

function T.replace_reports_backend_failure()
  local backend = FakeCache.new()
  local s = save("heartgold", backend)
  s:write(SAVE_PATH .. ".tmp", "new")
  ---@diagnostic disable: duplicate-set-field
  backend.replace = function()
    return false, "injected replace failure"
  end
  throwsCode("SAVE_REPLACE_FAILED", function()
    s:replace(SAVE_PATH .. ".tmp", SAVE_PATH)
  end)
end

return T
