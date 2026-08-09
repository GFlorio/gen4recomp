local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local RomExtractor = require("libs.rom.src.RomExtractor")
local DumpFixture = require("tests.support.DumpFixture")

local T = {}

local HG = "heartgold/"

local function extractOk(opts)
  local r = DumpFixture.extract(opts)
  Assert.notNil(r.report, "expected extraction to succeed: " .. tostring(r.err))
  return r
end

function T.writes_every_fat_entry_once()
  local r = extractOk()
  local files = r.backend.files
  -- One overlay, one unmapped, five named NitroFS files.
  Assert.notNil(files[HG .. "system/overlay9/overlay_0.bin"])
  Assert.notNil(files[HG .. "system/unmapped/file_1.bin"])
  Assert.equal(files[HG .. "romfs/a/0/0/2"], require("tests.support.NarcBuilder").build({ "P0", "P1" }))
  Assert.notNil(files[HG .. "romfs/a/0/4/1"])
  Assert.equal(files[HG .. "romfs/data/sound/gs_sound_data.sdat"], "SDAT-STUB")
  Assert.equal(r.report.fatEntryCount, 7)
  Assert.equal(r.report.unmappedFileCount, 1)
end

function T.writes_raw_system_sections()
  local r = extractOk()
  local files = r.backend.files
  Assert.equal(#files[HG .. "system/header.bin"], 0x200)
  Assert.notNil(files[HG .. "system/fnt.bin"])
  Assert.notNil(files[HG .. "system/fat.bin"])
  Assert.notNil(files[HG .. "system/arm9.bin"])
  Assert.notNil(files[HG .. "system/arm9_overlay_table.bin"])
end

function T.writes_marker_last_with_exact_content()
  local r = extractOk()
  local marker = r.backend.files[HG .. "rom-dump.complete"]
  local info = require("libs.rom.src.GameVersion").info("heartgold")
  Assert.equal(marker, RomExtractor.markerContent("heartgold", info.sha1))
end

function T.resolves_required_narcs_and_smoke_decodes()
  local r = extractOk()
  Assert.equal(r.report.resolvedRequiredNarcCount, 4)
  Assert.equal(r.report.matrix.width, 2)
  Assert.equal(r.report.matrix.height, 2)
  Assert.equal(r.report.matrix.name, "MM")
  Assert.equal(r.report.matrix.modelCellCount, 4)
end

-- A required NARC path missing from the FNT aborts before the marker is written.
function T.no_marker_on_required_narc_failure()
  local spec = DumpFixture.spec()
  local aZero = spec.tree.dirs[1].dirs[1].dirs -- a/0/{0,1,2,4}
  table.remove(aZero, 4) -- drop a/0/4 (map_matrices)
  local r = DumpFixture.extract({ spec = spec })
  Assert.isNil(r.report, "expected extraction to fail")
  Assert.isTrue(Errors.is(r.err))
  Assert.equal(r.err.code, "EXTRACT_REQUIRED_NARC_MISSING")
  Assert.isNil(r.backend.files["heartgold/rom-dump.complete"], "marker must be absent")
end

function T.generated_indexes_are_deterministic()
  local a = extractOk()
  local b = extractOk()
  for _, name in ipairs({ "rom_metadata", "romfs_index", "overlay_index" }) do
    local path = HG .. "data/generated/" .. name .. ".lua"
    Assert.equal(a.backend.files[path], b.backend.files[path], name .. " must be byte-identical")
  end
end

-- romfs_index round-trips: zero-based fileId keys and named source paths survive.
function T.romfs_index_preserves_zero_based_ids()
  local r = extractOk()
  local index = assert(r.cache:loadLua("data/generated/romfs_index.lua"))
  Assert.equal(index.files[0].kind, "overlay9")
  Assert.equal(index.files[1].kind, "unmapped")
  Assert.equal(index.files[2].sourcePath, "a/0/0/2")
  Assert.equal(index.files[5].sourcePath, "a/0/4/1")
  Assert.equal(index.fileCount, 7)
end

function T.does_not_touch_another_version_prefix()
  local FakeCache = require("tests.support.FakeCache")
  local backend = FakeCache.new()
  backend.files["soulsilver/rom-dump.complete"] = "SS-MARKER"
  backend.files["soulsilver/romfs/a/0/0/2"] = "SS-DATA"
  extractOk({ backend = backend })
  Assert.equal(backend.files["soulsilver/rom-dump.complete"], "SS-MARKER")
  Assert.equal(backend.files["soulsilver/romfs/a/0/0/2"], "SS-DATA")
end

function T.progress_is_monotonic_and_reaches_one()
  local last, sawFinal = -1, false
  extractOk({
    progress = function(p)
      Assert.isTrue(p.overall >= last, "overall regressed at stage " .. p.stage)
      last = p.overall
      if p.stage == "finalize" then
        sawFinal = true
      end
    end,
  })
  Assert.isTrue(sawFinal, "finalize stage must report")
  Assert.equal(last, 1)
end

return T
