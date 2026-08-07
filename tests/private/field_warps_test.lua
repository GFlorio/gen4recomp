-- Private Epic 8 target facts resolve the compiled Elm/New Bark warp pair all
-- the way through destination terrain selection without hardcoded endpoints.

local Assert = require("tests.support.Assert")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local WarpSystem = require("libs.engine.src.WarpSystem")

local T = {}

function T.elms_lab_and_new_bark_warps_resolve_both_directions(romFs)
  local maps = {
    [60] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
    [61] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
  }
  local loader = { load = function(_, mapId) return assert(maps[mapId]) end }

  local labWarp = assert(WarpSystem.findAt(maps[61], 4, 14))
  local outside = WarpSystem.resolveDestination(loader, maps[61], labWarp)
  Assert.equal(outside.destinationMap.mapId, 60)
  Assert.equal(outside.destinationWarp.index, 0)
  Assert.equal(outside.fieldX, 684)
  Assert.equal(outside.fieldZ, 393)
  Assert.notNil(maps[60].terrain:plate(outside.surfaceId))

  local townWarp = assert(WarpSystem.findAt(maps[60], 684, 393))
  local inside = WarpSystem.resolveDestination(loader, maps[60], townWarp)
  Assert.equal(inside.destinationMap.mapId, 61)
  Assert.equal(inside.destinationWarp.index, 0)
  Assert.equal(inside.fieldX, 4)
  Assert.equal(inside.fieldZ, 14)
  Assert.notNil(maps[61].terrain:plate(inside.surfaceId))
end

return T
