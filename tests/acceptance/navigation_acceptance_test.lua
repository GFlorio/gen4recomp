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
  return AcceptanceHarness.new():boot({ versionId = AcceptanceHarness.defaultVersion(), map = LAB, save = "fresh" })
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
-- Current-map protection has one owner (the runtime). While a destination is
-- staged, the runtime protects the complete resident footprint; after the
-- swap, protection transfers to the destination exactly once.
-- The return leg fires the town DOOR tile (behavior 105) in the non-rendering
-- runtime. The source door still owns semantic sound/ingress choreography;
-- the static destination has no close animation.
function T.tests.lab_town_round_trip_swaps_transitions_and_ownership()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = LAB, save = "fresh" })
    local ok, err = xpcall(function()
      requireGameCapability(game, "moveTo")
      requireGameCapability(game, "advanceUntil")
      requireGameCapability(game, "waitForTransition")
      requireGameCapability(game, "face")
      requireGameCapability(game, "ownership")
      local initial = game:snapshot()
      Assert.equal(initial.mapId, 61)
      Assert.equal(initial.mapSymbol, LAB)
      Assert.deepEqual({ initial.player.fieldX, initial.player.fieldZ }, { 4, 13 })
      game:face("south")
      local blocked = game:moveUntilBlocked("south")
      Assert.equal(blocked.mapId, 61)
      Assert.deepEqual({ blocked.player.fieldX, blocked.player.fieldZ }, { 4, 13 })
      game:setActorRemovalFlag("map:61:object:3")
      game:step()
      Assert.isNil(game:actor("map:61:object:3"))
      -- The lab door is a direction-gated warp (WARP_ENTRANCE_SOUTH): it
      -- fires on the input path, pressing south while standing on the tile.
      game:moveTo({ fieldX = 4, fieldZ = 14 })
      game:face("south")
      -- At the destination-load/swap boundary the staged resident footprint
      -- includes more than the source map, and the source remains protected
      -- until publication completes.
      game:advanceUntil("transition reaches the map swap", function(snapshot)
        return snapshot.transition.phase == "swap_map"
      end, 120)
      local stagedOwnership = game:ownership()
      local sourceProtected = false
      for _, mapId in ipairs(stagedOwnership.mapProtectedIds) do
        if mapId == game:snapshot().mapId then
          sourceProtected = true
        end
      end
      Assert.isTrue(sourceProtected, "the source map remains protected while staged")
      Assert.isTrue(stagedOwnership.mapProtections > 1, "the destination resident footprint is protected while staged")
      local transition = game:waitForTransition()
      Assert.equal(transition.source.mapSymbol, LAB)
      Assert.equal(transition.destination.mapSymbol, TOWN)
      Assert.equal(game:snapshot().mapSymbol, TOWN)
      -- The destination footprint is now committed. The destination itself
      -- must remain protected even when its neighboring resident maps are
      -- retained for the active physical window.
      local destinationOwnership = game:ownership()
      local destinationProtected = false
      for _, mapId in ipairs(destinationOwnership.mapProtectedIds) do
        if mapId == transition.destination.mapId then
          destinationProtected = true
        end
      end
      Assert.isTrue(destinationProtected, "the destination map is protected after publication")
      game:step()
      Assert.equal(game:snapshot().mapSymbol, TOWN)
      game:move("north")
      game:waitForTransition()
      Assert.equal(game:snapshot().mapSymbol, LAB)
      -- The headless source door completes without GPU presentation or an
      -- unresolved-door error. A choreo hold may cover the source egress while
      -- its fade-in has already completed; it is not a destination close wait.
      for _, snapshot in ipairs(game:trace()) do
        local phase = snapshot.transition.phase
        Assert.isTrue(
          phase == "idle"
            or phase == "fade_out"
            or phase == "load_destination"
            or phase == "swap_map"
            or phase == "fade_in"
            or phase == "choreo_hold",
          "a headless door warp has only source/egress choreography: " .. tostring(phase)
        )
      end
      Assert.isNil(game.runtime.transition.error, "a door warp in a door-less runtime records no unresolved-door error")
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
