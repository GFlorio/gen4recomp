-- Raw-dump contract: the extractor (writer) and the importer/readiness and
-- RomFs (readers) agree on the raw-dump identity files through the shared
-- RawDumpContract module. A contract path/schema change breaks one
-- authoritative constant here, not duplicated test literals.

local Assert = require("tests.support.Assert")
local RawDumpContract = require("romdump.src.source.RawDumpContract")
local RomImporter = require("romdump.src.source.RomImporter")
local RomExtractor = require("romdump.src.source.RomExtractor")
local RomFs = require("romdump.src.source.RomFs")
local DumpFixture = require("tests.support.DumpFixture")

local T = {}

local HG = "heartgold/"

local function extract()
  local r = DumpFixture.extract()
  Assert.notNil(r.report, "fixture extraction failed: " .. tostring(r.err))
  return r
end

-- Every generated identity file the writer produces lands at exactly the path
-- the shared contract names.
function T.writer_writes_identity_files_at_contract_paths()
  local r = extract()
  Assert.notNil(r.backend.files[HG .. RawDumpContract.METADATA_PATH], "metadata at the contract path")
  Assert.notNil(r.backend.files[HG .. RawDumpContract.ROMFS_INDEX_PATH], "romfs index at the contract path")
  Assert.notNil(r.backend.files[HG .. RawDumpContract.OVERLAY_INDEX_PATH], "overlay index at the contract path")
  Assert.notNil(r.backend.files[HG .. RawDumpContract.MARKER_PATH], "completion marker at the contract path")
end

-- The written schema identifiers are exactly the contract's, and the marker
-- content still names the extractor's cache format, so writer and readers
-- share one schema source.
function T.writer_writes_contract_schemas_and_marker()
  local r = extract()
  local metadata = assert(r.cache:loadLua(RawDumpContract.METADATA_PATH))
  local index = assert(r.cache:loadLua(RawDumpContract.ROMFS_INDEX_PATH))
  local overlayIndex = assert(r.cache:loadLua(RawDumpContract.OVERLAY_INDEX_PATH))
  Assert.equal(metadata.schema, RawDumpContract.METADATA_SCHEMA)
  Assert.equal(index.schema, RawDumpContract.ROMFS_INDEX_SCHEMA)
  Assert.equal(overlayIndex.schema, RawDumpContract.OVERLAY_INDEX_SCHEMA)
  Assert.equal(
    r.backend.files[HG .. RawDumpContract.MARKER_PATH],
    RomExtractor.markerContent(r.versionId, r.report.sha1)
  )
end

-- Readers accept the dump produced through the contract: RomFs opens the
-- identity files and the readiness contract accepts the marker plus the
-- required generated files.
function T.readers_accept_dump_through_contract_paths()
  local r = extract()
  local fs = assert(RomFs.open(r.versionId, r.cache))
  Assert.equal(fs:metadata().sha1, r.report.sha1)
  Assert.isTrue(RomImporter.isReady(r.versionId, r.cache))
end

-- Readiness depends on exactly the contract's identity files: removing any
-- one of them breaks it, so producer and consumer cannot drift apart.
function T.readiness_depends_on_every_contract_file()
  local paths = {
    RawDumpContract.METADATA_PATH,
    RawDumpContract.ROMFS_INDEX_PATH,
    RawDumpContract.OVERLAY_INDEX_PATH,
    RawDumpContract.MARKER_PATH,
  }
  for _, path in ipairs(paths) do
    local r = extract()
    r.cache:remove(path)
    Assert.isFalse(RomImporter.isReady(r.versionId, r.cache), "readiness must require " .. path)
  end
end

return { tests = T }
