local Assert = require("tests.support.Assert")
local RomFs = require("src.core.RomFs")
local MapMatrix = require("src.data.MapMatrix")
local DumpFixture = require("tests.support.DumpFixture")

local T = {}

local function openFs()
  local r = DumpFixture.extract()
  Assert.notNil(r.report, "fixture extraction failed: " .. tostring(r.err))
  local fs, err = RomFs.open(r.versionId, r.cache)
  Assert.notNil(fs, "RomFs.open failed: " .. tostring(err))
  return fs, r
end

function T.loads_index_and_builds_path_map()
  local fs = openFs()
  Assert.equal(fs:version(), "heartgold")
  Assert.equal(fs:fileCount(), 7)
  Assert.equal(fs:fileIdForPath("a/0/0/2"), 2)
  Assert.equal(fs:fileIdForPath("a/0/4/1"), 5)
  Assert.equal(fs:pathForFileId(6), "romfs/data/sound/gs_sound_data.sdat")
end

function T.reads_by_file_id_and_source_path()
  local fs = openFs()
  Assert.equal(fs:read(6), "SDAT-STUB")
  Assert.equal(fs:readSourcePath("data/sound/gs_sound_data.sdat"), "SDAT-STUB")
  -- fileId and source path resolve to the same bytes.
  Assert.equal(fs:read(6), fs:readSourcePath("data/sound/gs_sound_data.sdat"))
end

function T.info_resolves_source_path_and_file_id()
  local fs = openFs()
  Assert.equal(fs:info("a/0/4/1").fileId, 5)
  Assert.equal(fs:info(5).sourcePath, "a/0/4/1")
  Assert.equal(fs:info(0).kind, "overlay9")
end

function T.resolves_alias_and_symbol_to_path_and_file_id()
  local fs = openFs()
  local byAlias = fs:resolvedNarc("map_matrices")
  Assert.equal(byAlias.path, "a/0/4/1")
  Assert.equal(byAlias.fileId, 5)
  local bySymbol = fs:resolvedNarc("NARC_fielddata_mapmatrix_map_matrix")
  Assert.equal(bySymbol.fileId, 5)
end

function T.opens_narc_and_decodes_matrix()
  local fs = openFs()
  local narc, err = fs:openNarc("map_matrices")
  Assert.notNil(narc, "openNarc failed: " .. tostring(err))
  Assert.equal(narc:memberCount(), 1)
  local matrix = assert(MapMatrix.decode(narc:readMember(0), 0))
  Assert.equal(matrix.width, 2)
  Assert.equal(matrix.name, "MM")
  Assert.equal(matrix:modelIdAt(0, 0), 40)
end

-- NARC aliases resolve purely from the checked-in manifest plus the FNT path
-- index; no baked resolved_narcs table is produced or required. This means an
-- alias added after a dump was imported works without re-importing the ROM.
function T.resolves_without_a_baked_narc_table()
  local r = DumpFixture.extract()
  Assert.isNil(r.backend.files[r.versionId .. "/data/generated/resolved_narcs.lua"],
    "resolved_narcs.lua should no longer be produced")
  local fs = assert(RomFs.open(r.versionId, r.cache))
  local entry = fs:resolvedNarc("map_matrices")
  Assert.notNil(entry, "alias must resolve from manifest + FNT index")
  Assert.equal(entry.path, "a/0/4/1")
  Assert.equal(entry.fileId, 5)
  Assert.isNil(entry.memberCount, "member count is not precomputed; open the NARC for it")
  local narc, err = fs:openNarc("map_matrices")
  Assert.notNil(narc, "openNarc failed: " .. tostring(err))
  Assert.equal(narc:memberCount(), 1)
end

function T.unknown_source_path_returns_error()
  local fs = openFs()
  local data, err = fs:read("a/9/9/9")
  Assert.isNil(data)
  Assert.equal(err.code, "ROMFS_PATH_UNKNOWN")
end

function T.open_fails_when_not_ready()
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("src.import.CacheFs")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local fs, err = RomFs.open("heartgold", cache)
  Assert.isNil(fs)
  Assert.equal(err.code, "ROMFS_NOT_READY")
end

function T.open_rejects_schema_mismatch()
  local r = DumpFixture.extract()
  r.cache:writeLua("data/generated/romfs_index.lua", { schema = 2 })
  local fs, err = RomFs.open(r.versionId, r.cache)
  Assert.isNil(fs)
  Assert.equal(err.code, "ROMFS_SCHEMA_MISMATCH")
end

return T
