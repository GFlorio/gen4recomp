local Assert = require("tests.support.Assert")
local WorldManifest = require("romdump.src.digest.WorldManifest")

local T = {}

local function sample()
  return {
    { id = 61, symbol = "MAP_NEW_BARK_ELMS_LAB_1F", width = 1, height = 1,
      matrix = { memberId = 0, x = 0, z = 0 } },
    { id = 60, symbol = "MAP_NEW_BARK", width = 3, height = 3,
      matrix = { memberId = 0, x = 21, z = 12 } },
  }
end

function T.build_sorts_by_id_and_indexes()
  local m = WorldManifest.build(sample(), {
    { id = 1, symbol = "MAP_NOTHING", reason = "no_matching_cell", matchCount = 0 },
    { id = 0, symbol = "MAP_EVERYWHERE", reason = "default_header_filler", matchCount = 598 },
  })
  Assert.equal(m.maps[1].id, 60)
  Assert.equal(m.maps[2].id, 61)
  Assert.equal(m.bySymbol["MAP_NEW_BARK"], 60)
  Assert.equal(m.byId[61], 2)
  Assert.equal(m.maps[1].matrix.x, 21)
  Assert.equal(m.analysis.mapHeaderCount, 4)
  Assert.equal(m.analysis.renderableCount, 2)
  Assert.equal(m.analysis.excluded[1].id, 0)
  Assert.equal(m.analysis.excluded[2].id, 1)
end

function T.build_rejects_duplicate_symbol()
  local dup = sample()
  dup[1].symbol = "MAP_NEW_BARK"
  Assert.throws(function() WorldManifest.build(dup) end)
end

function T.build_rejects_duplicate_id()
  local dup = sample()
  dup[1].id = 60
  Assert.throws(function() WorldManifest.build(dup) end)
end

return T
