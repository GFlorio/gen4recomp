-- ROM-conformance test for canonical New Bark and Elm's Lab event members.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local LuaWriter = require("libs.codec.src.LuaWriter")

local T = {}

local EXPECTED = {
  [60] = { counts = { 5, 10, 5, 4 } },
  [61] = { counts = { 11, 4, 1, 2 } },
}

function T.target_members_compile_completely_and_deterministically(romFs)
  for mapId = 60, 61 do
    local bundle = assert(FieldMapDataCompiler.compile(romFs, mapId))
    local expected = EXPECTED[mapId]
    local events = bundle.field.events
    Assert.equal(#events.background, expected.counts[1])
    Assert.equal(#events.objects, expected.counts[2])
    Assert.equal(#events.warps, expected.counts[3])
    Assert.equal(#events.coordinates, expected.counts[4])
    local warp = events.warps[1]
    Assert.equal(warp.index, 0)
    Assert.equal(warp.y, 0)
    Assert.equal(warp.destinationWarpId, 0)
    local again = assert(FieldMapDataCompiler.compile(romFs, mapId))
    Assert.equal(LuaWriter.encode(bundle.field), LuaWriter.encode(again.field))
    Assert.equal(bundle.marker, again.marker)
  end
end

function T.every_catalog_map_event_member_decodes(romFs)
  local bundles = assert(FieldMapDataCompiler.compileAll(romFs))
  Assert.equal(#bundles, 538)
  for index, bundle in ipairs(bundles) do
    -- MAP_NOTHING and MAP_UNDERGROUND are source-header placeholders without
    -- field-data members, so neither produces a runtime record.
    local expectedMapId = index == 1 and 0 or index == 2 and 2 or index + 1
    Assert.equal(bundle.mapId, expectedMapId)
    Assert.equal(bundle.field.mapId, expectedMapId)
    Assert.isNil(bundle.field.source)
    Assert.isTrue(
      type(bundle.dependencies.eventMemberId) == "number",
      "source member identity lives in the dependency record"
    )
  end
end

return require("tests.rom.support.RomSuite").fromFacts(T)
