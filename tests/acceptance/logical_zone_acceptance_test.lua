-- Production-composed acceptance for seamless logical-zone ownership. The
-- route, physical coverage, collision, actors, scripts, and field metadata
-- all come from the ROM-backed runtime; only the save root and graphics output
-- are substituted by AcceptanceHarness.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "navigation", "logical-zone" },
  },
  tests = {},
}

local NEW_BARK = "MAP_NEW_BARK"
local ROUTE_29_ID = 33
local ROUTE_29 = "MAP_ROUTE_29"
local ROUTE_29_TARGET = { fieldX = 626, fieldZ = 389 }
local NEW_BARK_ID = 60

local function withTown(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = NEW_BARK, save = "fresh" })
    local ok, err = xpcall(function()
      fn(game)
      Assert.equal(game:renderAttempts(), 0, "logical-zone acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

local function moveToRoute29(game)
  return game:moveTo(ROUTE_29_TARGET, ROUTE_29_ID)
end

-- Crossing a committed physical header changes logical ownership in place.
-- The identity assertions deliberately observe the production
-- objects directly; no transition or replacement helper is assembled here.
function T.tests.new_bark_to_route_29_is_a_seamless_zone_change()
  withTown(function(game)
    local player = assert(game.runtime.player, "production player is required")
    local camera = assert(game.runtime.camera, "production camera is required")
    local playerVisual = assert(game.runtime.playerVisual, "production player visual is required")
    local physicalOwner = assert(game.runtime.physicalCoverage, "production physical world is required")
    local before = game:snapshot()

    local after = moveToRoute29(game)

    Assert.equal(before.mapSymbol, NEW_BARK)
    Assert.equal(after.mapSymbol, ROUTE_29)
    Assert.equal(after.mapId, ROUTE_29_ID)
    Assert.equal(
      after.transition.phase,
      "idle",
      string.format(
        "unexpected transition phase=%s map=%s player=(%s,%s) zone=%s->%s kind=%s warp=%s error=%s",
        tostring(after.transition.phase),
        tostring(after.mapId),
        tostring(after.player.fieldX),
        tostring(after.player.fieldZ),
        tostring(game.runtime.lastZoneChange and game.runtime.lastZoneChange.oldMapId),
        tostring(game.runtime.lastZoneChange and game.runtime.lastZoneChange.newMapId),
        tostring(game.runtime.transition.sourceKind),
        tostring(game.runtime.transition.sourceWarp and game.runtime.transition.sourceWarp.index),
        tostring(game.runtime.transition.error)
      )
    )
    Assert.equal(game.runtime.player, player, "zone ownership must preserve the player object")
    Assert.equal(game.runtime.camera, camera, "zone ownership must preserve the camera object")
    Assert.equal(game.runtime.playerVisual, playerVisual, "zone ownership must preserve the player visual")
    Assert.equal(game.runtime.physicalCoverage, physicalOwner, "zone ownership must preserve the physical world")
    Assert.equal(game.runtime.runtimeMap.coverage, physicalOwner, "logical view must use the session physical world")
    local seamSource = assert(game.lastTransition and game.lastTransition.source, "zone source snapshot required")
    local displacement = math.abs(after.player.fieldX - seamSource.player.fieldX)
      + math.abs(after.player.fieldZ - seamSource.player.fieldZ)
    Assert.equal(displacement, 1, "zone change must commit exactly one movement step")

    local change = assert(game.runtime.lastZoneChange, "the committed zone change must be observable")
    Assert.equal(change.oldMapId, before.mapId)
    Assert.equal(change.newMapId, ROUTE_29_ID)
    Assert.equal(change.oldMapSection, "NEW_BARK_TOWN")
    Assert.equal(change.newMapSection, "ROUTE_29")
    Assert.isTrue(change.mapSectionChanged)
  end)
end

-- Destination ownership must be visible to the ordinary
-- post-step consumers immediately after the crossing, before another input
-- tick can run. These are production runtime state observations, not calls to
-- script, actor, weather, or audio internals.
function T.tests.destination_context_is_authoritative_after_crossing()
  withTown(function(game)
    local before = game:snapshot()
    local after = moveToRoute29(game)
    local runtime = game.runtime

    Assert.equal(after.mapSymbol, ROUTE_29)
    Assert.equal(runtime.runtimeMap.mapId, ROUTE_29_ID)
    Assert.equal(runtime.runtimeMap.mapSymbol, ROUTE_29)
    Assert.equal(runtime.scripts.mapSource.mapId, ROUTE_29_ID)
    Assert.equal(runtime.actors.maps[ROUTE_29_ID] ~= nil, true)
    Assert.equal(runtime.actors.maps[before.mapId], nil)
    Assert.equal(runtime.weatherRuntime.mapId, ROUTE_29_ID)
    Assert.equal(runtime.audio:currentMapId(), ROUTE_29_ID)
    Assert.equal(game.runtime.lastZoneChange.newMapId, ROUTE_29_ID)
    Assert.equal(runtime.runtimeMap.coverage, runtime.physicalCoverage)
    Assert.isNil(runtime.mapLoader.physicalCoverage, "logical loader must not own the physical world")
  end)
end

-- Physical movement within the source header must not repeat
-- logical-zone work. The same production objects remain active and no new
-- semantic record is emitted for a same-header step.
function T.tests.same_header_step_is_a_zone_noop()
  withTown(function(game)
    local player = assert(game.runtime.player, "production player is required")
    local camera = assert(game.runtime.camera, "production camera is required")
    local playerVisual = assert(game.runtime.playerVisual, "production player visual is required")
    local before = game:snapshot()

    game:moveTo({ fieldX = before.player.fieldX + 1, fieldZ = before.player.fieldZ })
    local after = game:advanceUntil("same-header movement settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 30)

    Assert.equal(after.mapId, before.mapId)
    Assert.equal(after.mapSymbol, NEW_BARK)
    Assert.equal(after.transition.phase, "idle")
    Assert.equal(game.runtime.player, player)
    Assert.equal(game.runtime.camera, camera)
    Assert.equal(game.runtime.playerVisual, playerVisual)
    Assert.isNil(game.runtime.lastZoneChange, "same-header movement must not emit a zone-change record")
  end)
end

-- A live session must cross the same outdoor seam repeatedly without
-- replacing the physical-world owner. Each committed seam remains one tile,
-- updates the current logical map, and settles without a transition phase.
function T.tests.repeated_new_bark_route_29_round_trip_preserves_physical_identity()
  withTown(function(game)
    local initial = game:snapshot()
    local physicalOwner = assert(game.runtime.physicalCoverage, "physical coverage owner is required")

    local function assertSeam(destinationMapId, destinationSymbol)
      local transition = assert(game.lastTransition, "logical seam transition record is required")
      local destination = transition.destination
      local displacement = math.abs(destination.player.fieldX - transition.source.player.fieldX)
        + math.abs(destination.player.fieldZ - transition.source.player.fieldZ)
      Assert.equal(displacement, 1, "logical seam must commit exactly one tile")
      Assert.equal(destination.mapId, destinationMapId)
      Assert.equal(destination.mapSymbol, destinationSymbol)
      Assert.equal(destination.transition.phase, "idle")
      Assert.equal(game:snapshot().mapId, destinationMapId)
      Assert.equal(game:snapshot().mapSymbol, destinationSymbol)
      Assert.equal(game.runtime.runtimeMap.coverage, physicalOwner)
      Assert.equal(game.runtime.physicalCoverage, physicalOwner)
      Assert.isNil(game.runtime.mapLoader.physicalCoverage, "logical cache must not own physical coverage")
    end

    for _ = 1, 2 do
      moveToRoute29(game)
      assertSeam(ROUTE_29_ID, ROUTE_29)

      game:moveTo({ fieldX = initial.player.fieldX, fieldZ = initial.player.fieldZ }, NEW_BARK_ID)
      assertSeam(NEW_BARK_ID, NEW_BARK)
    end
  end)
end

return T
