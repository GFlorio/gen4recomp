local Assert = require("tests.support.Assert")
local WorldManifest = require("romdump.src.digest.WorldManifest")

local T = {}

local function sample()
  return {
    {
      id = 61,
      symbol = "MAP_NEW_BARK_ELMS_LAB_1F",
      width = 1,
      height = 1,
      matrix = { memberId = 0, x = 0, z = 0 },
    },
    { id = 60, symbol = "MAP_NEW_BARK", width = 3, height = 3, matrix = { memberId = 0, x = 21, z = 12 } },
  }
end

local function selectionExcluded()
  return {
    { id = 3, symbol = "MAP_NOTHING", reason = "no_matching_cell", matchCount = 0 },
    { id = 1, symbol = "MAP_ELSEWHERE", reason = "no_matching_cell", matchCount = 0 },
  }
end

local function compileExcluded()
  return {
    {
      id = 0,
      symbol = "MAP_EVERYWHERE",
      errorCode = "NSBMD_STATIC_UNSUPPORTED_SBC_COMMAND",
      message = "BBY is unsupported",
      context = { model = "snap_came_in", opcode = 8 },
    },
  }
end

function T.build_sorts_by_id_and_indexes()
  local m = WorldManifest.build(sample(), selectionExcluded(), compileExcluded())
  Assert.equal(m.maps[1].id, 60)
  Assert.equal(m.maps[2].id, 61)
  Assert.equal(m.bySymbol["MAP_NEW_BARK"], 60)
  Assert.equal(m.byId[61], 2)
  Assert.equal(m.maps[1].matrix.x, 21)
  Assert.equal(m.analysis.mapHeaderCount, 5)
  Assert.equal(m.analysis.renderableCount, 2)
end

-- The two exclusion kinds mean different things, so they are separate
-- collections: an unresolved cell is a selection limit, a compile failure is an
-- asset-support gap with a code and context to act on.
function T.selection_and_compile_exclusions_are_separate_and_sorted()
  local m = WorldManifest.build(sample(), selectionExcluded(), compileExcluded())
  Assert.equal(#m.analysis.excluded, 2)
  Assert.equal(m.analysis.excluded[1].id, 1)
  Assert.equal(m.analysis.excluded[2].id, 3)
  Assert.equal(#m.analysis.compileExcluded, 1)
  Assert.equal(m.analysis.compileExcluded[1].symbol, "MAP_EVERYWHERE")
  Assert.equal(m.analysis.compileExcluded[1].errorCode, "NSBMD_STATIC_UNSUPPORTED_SBC_COMMAND")
  Assert.equal(m.analysis.compileExcluded[1].context.model, "snap_came_in")
end

function T.build_defaults_both_exclusion_collections_to_empty()
  local m = WorldManifest.build(sample())
  Assert.deepEqual(m.analysis.excluded, {})
  Assert.deepEqual(m.analysis.compileExcluded, {})
  Assert.equal(m.analysis.mapHeaderCount, 2)
end

function T.a_map_cannot_be_excluded_twice_across_the_collections()
  Assert.throws(function()
    WorldManifest.build(
      sample(),
      { { id = 0, symbol = "MAP_EVERYWHERE", reason = "no_matching_cell" } },
      compileExcluded()
    )
  end)
end

function T.a_compile_excluded_map_cannot_also_be_renderable()
  Assert.throws(function()
    WorldManifest.build(sample(), {}, { { id = 60, symbol = "MAP_NEW_BARK", errorCode = "X", message = "y" } })
  end)
end

function T.build_rejects_duplicate_symbol()
  local dup = sample()
  dup[1].symbol = "MAP_NEW_BARK"
  Assert.throws(function()
    WorldManifest.build(dup)
  end)
end

function T.build_rejects_duplicate_id()
  local dup = sample()
  dup[1].id = 60
  Assert.throws(function()
    WorldManifest.build(dup)
  end)
end

return T
