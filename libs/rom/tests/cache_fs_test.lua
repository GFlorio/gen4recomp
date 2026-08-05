local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local function cache(versionId, backend)
  return CacheFs.forVersion(versionId, backend or FakeCache.new())
end

local T = {}

function T.prefix_reflects_version()
  Assert.equal(cache("heartgold"):prefix(), "heartgold/")
  Assert.equal(cache("soulsilver"):prefix(), "soulsilver/")
end

function T.write_lands_under_version_prefix()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("system/header.bin", "HDR")
  Assert.equal(backend.files["heartgold/system/header.bin"], "HDR")
end

function T.read_round_trips_written_bytes()
  local c = cache("heartgold")
  c:write("a/0/4/1", "matrix")
  Assert.equal(c:read("a/0/4/1"), "matrix")
end

function T.read_missing_returns_nil()
  Assert.isNil(cache("heartgold"):read("nope"))
end

function T.exists_checks_presence_and_type()
  local c = cache("heartgold")
  c:write("romfs/a/0/0/2", "x")
  Assert.isTrue(c:exists("romfs/a/0/0/2"))
  Assert.isTrue(c:exists("romfs/a/0/0/2", "file"))
  Assert.isFalse(c:exists("romfs/a/0/0/2", "directory"))
  Assert.isTrue(c:exists("romfs/a/0/0", "directory"))
  Assert.isFalse(c:exists("absent"))
end

-- write() must materialize the parent chain so the love backend (no implicit
-- mkdir) can land a deeply nested NitroFS file.
function T.write_creates_parent_directories()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("romfs/a/0/0/0", "data")
  Assert.isTrue(backend.dirs["heartgold/romfs/a/0/0"], "parent directory must be created")
end

function T.remove_tree_recursively_clears_subtree()
  local c = cache("heartgold")
  c:write("romfs/a/0/0/0", "0")
  c:write("romfs/a/0/0/1", "1")
  c:write("romfs/data/x", "x")
  c:removeTree("romfs/a")
  Assert.isNil(c:read("romfs/a/0/0/0"))
  Assert.isNil(c:read("romfs/a/0/0/1"))
  Assert.equal(c:read("romfs/data/x"), "x")
end

-- One version's operations must never see or clear another's.
function T.versions_are_isolated()
  local backend = FakeCache.new()
  local hg = cache("heartgold", backend)
  local ss = cache("soulsilver", backend)
  hg:write("marker", "HG")
  ss:write("marker", "SS")
  Assert.equal(hg:read("marker"), "HG")
  Assert.equal(ss:read("marker"), "SS")
  ss:removeTree("")
  Assert.equal(hg:read("marker"), "HG")
  Assert.isNil(ss:read("marker"))
end

function T.rejects_absolute_paths()
  Assert.throws(function() cache("heartgold"):write("/etc/passwd", "x") end)
end

function T.rejects_drive_letters()
  Assert.throws(function() cache("heartgold"):write("C:/x", "x") end)
end

function T.rejects_parent_components()
  Assert.throws(function() cache("heartgold"):read("../soulsilver/marker") end)
  Assert.throws(function() cache("heartgold"):read("a/../../b") end)
end

function T.rejects_dot_and_nul_components()
  Assert.throws(function() cache("heartgold"):read("a/./b") end)
  Assert.throws(function() cache("heartgold"):read("a\0b") end)
end

function T.lua_round_trip_is_deterministic()
  local c = cache("heartgold")
  local value = { schema = 1, files = { [0] = { fileId = 0, size = 12 } } }
  c:writeLua("data/generated/x.lua", value)
  Assert.deepEqual(c:loadLua("data/generated/x.lua"), value)
end

function T.load_lua_missing_returns_nil_err()
  local data, err = cache("heartgold"):loadLua("data/generated/absent.lua")
  Assert.isNil(data)
  Assert.notNil(err)
end

return T
