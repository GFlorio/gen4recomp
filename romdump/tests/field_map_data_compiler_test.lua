-- Deterministic field-map compilation, cache readiness/rollback, and inspector
-- output using a synthetic zone-event member.

local Assert = require("tests.support.Assert")
local Builder = require("tests.support.ZoneEventsBuilder")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local FieldMapDataCacheWriter = require("romdump.src.digest.FieldMapDataCacheWriter")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMapDataInspector = require("romdump.src.digest.FieldMapDataInspector")
local FieldMapDataFixture = require("tests.support.FieldMapDataFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")

local T = {}

local function fixture()
  local member = Builder.build({
    warps = { { x = 684, z = 393, destinationMapId = 61, destinationWarpId = 0, y = 0 } },
  })
  local romFs = FieldMapDataFixture.build({ zoneEventsMember = member })
  local function sha1(bytes)
    return bytes == member and "member-sha" or "archive-sha"
  end
  local function hashLua()
    return "dependency-sha"
  end
  return romFs, sha1, hashLua
end

local function allMapsFixture()
  local romFs = FieldMapDataFixture.build()
  local function sha1()
    return "archive-sha"
  end
  local function hashLua()
    return "dependency-sha"
  end
  return romFs, sha1, hashLua
end

local function playerHouseHeader()
  return string.char(
    0x01,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x06,
    0x41,
    0x03,
    0x00,
    0x07,
    0x00,
    0x06,
    0x41,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00
  )
end

function T.compiles_catalog_identity_source_and_events()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.equal(bundle.mapId, 60)
  Assert.equal(bundle.field.schema, "g4-field-map-v7")
  Assert.equal(bundle.field.mapSymbol, "MAP_NEW_BARK")
  Assert.equal(bundle.field.cameraType, 0)
  -- Source identity lives only in the dependency record; the runtime asset
  -- carries normalized events plus the semantic bank associations.
  Assert.isNil(bundle.field.source)
  Assert.equal(bundle.field.events.warps[1].x, 684)
  Assert.equal(bundle.dependencies.eventMemberId, 57)
  Assert.equal(bundle.dependencies.eventMemberSha1, "member-sha")
  Assert.equal(bundle.dependencies.eventNarc.fileId, 99)
  Assert.equal(bundle.dependencies.eventNarc.sha1, "archive-sha")
  -- The audio policy resolves through the map matrix: the matrix cell of map
  -- 60 names land member 244, whose BGS payload feeds the soundplates array.
  Assert.equal(bundle.dependencies.landDataMemberId, 244)
  Assert.equal(bundle.marker, "g4-field-map-cache-v1:rom-sha:60:dependency-sha")

  local again = assert(FieldMapDataCompiler.compile(romFs, "MAP_NEW_BARK", sha1, hashLua))
  Assert.equal(LuaWriter.encode(bundle.field), LuaWriter.encode(again.field))
end

function T.emits_strict_init_script_array_for_every_map()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.equal(bundle.field.schema, "g4-field-map-v7")
  Assert.deepEqual(bundle.field.initScripts, {})
end

function T.player_house_header_618_resolves_scripts_in_body_bank_845()
  local romFs = FieldMapDataFixture.build({ scriptHeaderMember = playerHouseHeader() })
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 63, function()
    return "archive-sha"
  end, function()
    return "dependency-sha"
  end))
  Assert.equal(bundle.field.scriptBankId, 845)
  Assert.deepEqual(bundle.field.initScripts[1].rules, {
    {
      variableId = 0x4106,
      equals = 3,
      scriptId = "vanilla.hgss.scr_seq.0845.script_006",
    },
    {
      variableId = 0x4106,
      equals = 0,
      scriptId = "vanilla.hgss.scr_seq.0845.script_000",
    },
  })
end

function T.map_header_music_fields_are_emitted_as_canonical_sequence_references()
  -- The frozen catalog's dayMusic/nightMusic become canonical audio sequence
  -- references (map 60 = SEQ_GS_T_WAKABA, map 61 = SEQ_GS_UTSUGI_RABO) in the
  -- generated field record, so runtime music policy never branches on map ids
  -- and never decorates a bare source suffix. The music record also carries
  -- the generated policy blocks: ordered flag overrides (empty for maps with
  -- no source rule) and the source surfing traversal override on every record.
  local romFs, sha1, hashLua = fixture()
  local newBark = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.deepEqual(newBark.field.music, {
    day = "SEQ_GS_T_WAKABA",
    night = "SEQ_GS_T_WAKABA",
    flagOverrides = {},
    traversalOverrides = {
      { traversal = "surfing", sequence = "SEQ_GS_NAMINORI", unlessFlagId = 0x99A },
    },
  })
  Assert.deepEqual(newBark.field.soundplates, {}, "an empty land BGS payload emits no soundplates")
  local elmsLab = assert(FieldMapDataCompiler.compile(romFs, 61, sha1, hashLua))
  Assert.equal(elmsLab.field.music.day, "SEQ_GS_UTSUGI_RABO")
  Assert.equal(elmsLab.field.music.night, "SEQ_GS_UTSUGI_RABO")
end

function T.map_header_message_and_script_banks_are_emitted()
  -- Maps 60/61 associate to message banks 542/543 through the frozen map
  -- catalog (src/data/map_headers.h); the artifact must carry them so runtime
  -- code never branches on map ids.
  local romFs, sha1, hashLua = fixture()
  local newBark = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.equal(newBark.field.messageBankId, 542)
  Assert.equal(newBark.field.scriptBankId, 842)
  local elmsLab = assert(FieldMapDataCompiler.compile(romFs, 61, sha1, hashLua))
  Assert.equal(elmsLab.field.messageBankId, 543)
  Assert.equal(elmsLab.field.scriptBankId, 843)
end

function T.writer_commits_marker_last_and_inspector_is_stable()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.equal(FieldMapDataCacheWriter.write(cache, bundle), bundle.marker)
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, bundle.marker))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker .. "-old"))

  local report = FieldMapDataInspector.inspect(bundle.field, bundle.dependencies)
  Assert.deepEqual(report.counts, { background = 0, objects = 0, warps = 1, coordinates = 0 })
  local lines = FieldMapDataInspector.lines(report)
  Assert.equal(lines[1], "field-map\tmap=60\tsymbol=MAP_NEW_BARK\tcamera=0\tmember=57\tcounts=0/0/1/0")
  Assert.equal(lines[2], "warp\tmap=60\tindex=0\tx=684\tz=393\ty=0\tdestination=61:0")
end

function T.writer_failure_rolls_back_only_its_map()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  local backend = FakeCache.new()
  local originalWrite = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("dependencies.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:write("rom-dump.complete", "raw")
  Assert.throws(function()
    FieldMapDataCacheWriter.write(cache, bundle)
  end)
  Assert.isFalse(cache:exists(FieldMapDataCache.mapDir(60)))
  Assert.isTrue(cache:exists("rom-dump.complete"))
end

function T.failed_rebuild_preserves_the_previous_record()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldMapDataCacheWriter.write(cache, first)
  local originalWrite = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("field.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  second.marker = FieldMapDataCache.marker(sha1, 60, "new-dep-hash")
  Assert.throws(function()
    FieldMapDataCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, first.marker), "the previous record remains ready")
  Assert.equal(cache:read(FieldMapDataCache.markerPath(60)), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-map-data-60"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldMapDataCacheWriter.write(cache, second)
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, second.marker), "a retry publishes the new record")
end

function T.compile_all_covers_the_catalog_in_numeric_order()
  local romFs, sha1, hashLua = allMapsFixture()
  local bundles = assert(FieldMapDataCompiler.compileAll(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.equal(#bundles, 540)
  for index, bundle in ipairs(bundles) do
    Assert.equal(bundle.mapId, index - 1)
    Assert.equal(bundle.field.mapId, index - 1)
    FieldMapDataCacheWriter.write(cache, bundle)
    Assert.isTrue(FieldMapDataCache.isReady(cache, bundle.mapId, bundle.marker))
  end
end

return { tests = T }
