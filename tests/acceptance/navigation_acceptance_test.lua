-- Production-composed navigation and warp contracts. These scenarios drive
-- only AcceptanceHarness semantic input; they never assemble field internals
-- or permit GPU presentation.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "navigation", "warp" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN = "MAP_NEW_BARK"

local function bootLab()
  return AcceptanceHarness.new():boot({ versionId = "heartgold", map = LAB, save = "fresh" })
end

local function requireGameCapability(game, name)
  Assert.isTrue(
    type(game[name]) == "function",
    "acceptance harness must expose " .. name .. " for production navigation"
  )
end

local function withLab(fn)
  local game = bootLab()
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- NAV-01/02: occupancy and collision are both real movement constraints. Elm
-- turns the player without letting him enter his cell, and a known wall tile
-- rejects the step while preserving facing; the named route is deliberately
-- semantic, no test-owned movement loop may substitute for session input.
function T.tests.occupancy_and_collision_constrain_lab_movement()
  withLab(function(game)
    requireGameCapability(game, "moveTo")
    requireGameCapability(game, "move")
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    game:move("north")
    game:advanceUntil("Elm occupancy resolves", function(snapshot)
      return snapshot.player.motion == "idle" and snapshot.player.facing == "north"
    end, 120)
    local snapshot = game:snapshot()
    Assert.deepEqual({ snapshot.player.fieldX, snapshot.player.fieldZ }, { 6, 6 })

    requireGameCapability(game, "moveUntilBlocked")
    game:moveTo({ fieldX = 3, fieldZ = 14 })
    local blocked = game:moveUntilBlocked("south")
    Assert.equal(blocked.player.facing, "south")
    Assert.deepEqual({ blocked.player.fieldX, blocked.player.fieldZ }, { 3, 14 })
  end)
end

-- NAV-03..07: a semantic lab-town round trip runs for every ready version,
-- swaps to New Bark exactly once without immediately returning, releases and
-- reacquires map/actor/session ownership, and ends back in the lab only when
-- the player actually faces the town warp.
function T.tests.lab_town_round_trip_swaps_transitions_and_ownership()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = LAB, save = "fresh" })
    local ok, err = xpcall(function()
      requireGameCapability(game, "moveTo")
      requireGameCapability(game, "waitForTransition")
      requireGameCapability(game, "face")
      requireGameCapability(game, "ownership")
      game:moveTo({ fieldX = 4, fieldZ = 14 })
      local transition = game:waitForTransition()
      Assert.equal(transition.source.mapSymbol, LAB)
      Assert.equal(transition.destination.mapSymbol, TOWN)
      Assert.equal(game:snapshot().mapSymbol, TOWN)
      game:step()
      Assert.equal(game:snapshot().mapSymbol, TOWN)

      game:move("south")
      game:face("north")
      game:waitForTransition()
      Assert.equal(game:snapshot().mapSymbol, LAB)
      local ownership = game:ownership()
      Assert.equal(ownership.mapProtections, 1)
      Assert.equal(ownership.activeActorMaps, 1)
      Assert.equal(ownership.sessionReferences, 1)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
