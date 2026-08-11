-- Production-composed navigation and warp contracts. These scenarios drive
-- only AcceptanceHarness semantic input; they never assemble field internals
-- or permit GPU presentation.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
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

-- NAV-01: the named route is deliberately semantic; no test-owned movement
-- loop may substitute for session input processing.
function T.tests.canonical_lab_path_reaches_the_cell_south_of_elm()
  withLab(function(game)
    requireGameCapability(game, "moveTo")
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    local snapshot = game:snapshot()
    Assert.deepEqual({ snapshot.player.fieldX, snapshot.player.fieldZ }, { 6, 6 })
  end)
end

function T.tests.elm_occupancy_turns_the_player_without_entering_elms_cell()
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
  end)
end

function T.tests.known_lab_collision_rejects_movement_and_preserves_facing()
  withLab(function(game)
    requireGameCapability(game, "moveTo")
    requireGameCapability(game, "moveUntilBlocked")
    game:moveTo({ fieldX = 3, fieldZ = 14 })
    local snapshot = game:moveUntilBlocked("south")
    Assert.equal(snapshot.player.facing, "south")
    Assert.deepEqual({ snapshot.player.fieldX, snapshot.player.fieldZ }, { 3, 14 })
  end)
end

function T.tests.lab_exit_warp_swaps_to_new_bark_exactly_once()
  withLab(function(game)
    requireGameCapability(game, "moveTo")
    requireGameCapability(game, "waitForTransition")
    game:moveTo({ fieldX = 4, fieldZ = 14 })
    local transition = game:waitForTransition()
    Assert.equal(transition.source.mapSymbol, LAB)
    Assert.equal(transition.destination.mapSymbol, TOWN)
    Assert.equal(game:snapshot().mapSymbol, TOWN)
  end)
end

function T.tests.arrival_on_town_warp_cell_does_not_immediately_return_to_lab()
  withLab(function(game)
    requireGameCapability(game, "moveTo")
    requireGameCapability(game, "waitForTransition")
    game:moveTo({ fieldX = 4, fieldZ = 14 })
    game:waitForTransition()
    game:step()
    Assert.equal(game:snapshot().mapSymbol, TOWN)
  end)
end

function T.tests.town_facing_warp_returns_to_the_lab()
  withLab(function(game)
    requireGameCapability(game, "moveTo")
    requireGameCapability(game, "waitForTransition")
    requireGameCapability(game, "face")
    game:moveTo({ fieldX = 4, fieldZ = 14 })
    game:waitForTransition()
    game:move("south")
    game:face("north")
    local transition = game:waitForTransition()
    Assert.equal(transition.destination.mapSymbol, LAB)
  end)
end

function T.tests.round_trip_releases_and_reacquires_map_actor_and_session_ownership()
  withLab(function(game)
    requireGameCapability(game, "moveTo")
    requireGameCapability(game, "waitForTransition")
    requireGameCapability(game, "ownership")
    game:moveTo({ fieldX = 4, fieldZ = 14 })
    game:waitForTransition()
    game:move("south")
    game:face("north")
    game:waitForTransition()
    local ownership = game:ownership()
    Assert.equal(ownership.mapProtections, 1)
    Assert.equal(ownership.activeActorMaps, 1)
    Assert.equal(ownership.sessionReferences, 1)
  end)
end

function T.tests.semantic_lab_town_round_trip_runs_for_every_ready_version()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = LAB, save = "fresh" })
    local ok, err = xpcall(function()
      requireGameCapability(game, "moveTo")
      requireGameCapability(game, "waitForTransition")
      requireGameCapability(game, "face")
      game:moveTo({ fieldX = 4, fieldZ = 14 })
      game:waitForTransition()
      game:move("south")
      game:face("north")
      game:waitForTransition()
      Assert.equal(game:snapshot().mapSymbol, LAB)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
