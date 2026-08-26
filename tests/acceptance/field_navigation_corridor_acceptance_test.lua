-- One production-composed ROM-backed corridor proving obstacle handling,
-- streamed outdoor travel, logical-zone ownership, persistence, and the
-- existing discontinuous building transition lifecycle.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = { capabilities = { "rom_dump", "derived_cache" }, tags = { "field", "corridor", "navigation" } },
  tests = {},
}

local function uniqueActors(snapshot)
  local seen = {}
  for actorId in pairs(snapshot.actors) do
    Assert.isNil(seen[actorId], "active actor IDs must be unique")
    seen[actorId] = true
  end
end

local function assertResident(snapshot)
  Assert.notNil(snapshot.coverage, "production coverage status is required")
  Assert.isTrue(snapshot.coverage.residentCount <= 9, "physical residency must remain bounded")
  Assert.equal(snapshot.coverage.anchorX, math.floor(snapshot.player.fieldX / 32))
  Assert.equal(snapshot.coverage.anchorZ, math.floor(snapshot.player.fieldZ / 32))
  Assert.equal(snapshot.player.fieldX, math.floor(snapshot.player.fieldX))
  Assert.equal(snapshot.player.fieldZ, math.floor(snapshot.player.fieldZ))
  uniqueActors(snapshot)
end

local function withVersion(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local romFs, err = RomFs.open(versionId)
    assert(romFs, tostring(err))
    local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
    romFs:close()
    local game = harness:boot({ versionId = versionId, map = "MAP_NEW_BARK", save = "fresh" })
    local ok, failure = xpcall(function()
      fn(game, facts)
      Assert.equal(game:renderAttempts(), 0, "navigation acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(failure, 0)
    end
  end)
end

local function moveTo(game, point)
  return game:moveTo({ fieldX = point.fieldX, fieldZ = point.fieldZ })
end

local function assertSeam(game, expectedMapId, expectedMapSymbol, label)
  local transition = assert(game.lastTransition, label .. " must publish a seam transition")
  local source = transition.source
  local destination = transition.destination
  local displacement = math.abs(destination.player.fieldX - source.player.fieldX)
    + math.abs(destination.player.fieldZ - source.player.fieldZ)
  Assert.equal(displacement, 1, label .. " must commit exactly one tile")
  Assert.equal(destination.mapId, expectedMapId)
  Assert.equal(destination.mapSymbol, expectedMapSymbol)
  Assert.equal(destination.transition.phase, "idle", label .. " must not start a fade transition")
  Assert.isNil(game.runtime.transition.sourceKind, label .. " must remain outside the warp transition lifecycle")
end

function T.tests.corridor_traverses_water_zone_streaming_grass_ledge_and_returns()
  withVersion(function(game, facts)
    local initial = game:snapshot()
    local physicalOwner = assert(game.runtime.physicalCoverage, "physical coverage owner is required")
    assertResident(initial)

    local waterApproach = moveTo(game, facts.water.approach)
    local beforeWater = waterApproach.player
    game:move(facts.water.direction)
    local afterWater = game:advanceUntil("water rejection settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 32)
    Assert.equal(afterWater.player.fieldX, beforeWater.fieldX)
    Assert.equal(afterWater.player.fieldZ, beforeWater.fieldZ)
    Assert.equal(afterWater.player.facing, facts.water.direction)

    local route = game:moveTo(facts.zoneBoundary, 33)
    Assert.equal(route.mapId, 33)
    Assert.equal(route.transition.phase, "idle", "seam crossing must not start a transition")
    Assert.notNil(route.zoneChange, "seam crossing must publish zone ownership")
    assertSeam(game, 33, "MAP_ROUTE_29", "New Bark to Route 29")
    Assert.equal(game.runtime.physicalCoverage, physicalOwner, "seam crossing must preserve the physical world")
    assertResident(route)

    local far = moveTo(game, facts.far)
    assertResident(far)
    local grass = moveTo(game, facts.grass)
    Assert.notNil(grass.terrainEffects, "terrain effect status is required")
    Assert.isTrue(#grass.terrainEffects.instances > 0, "grass displacement must emit an effect")
    assertResident(grass)

    local ledgeStart = moveTo(game, facts.ledge).player
    game:face(facts.ledge.direction)
    game:move(facts.ledge.direction)
    local landing = game:advanceUntil("ledge jump settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 48)
    Assert.equal(
      math.abs(landing.player.fieldX - ledgeStart.fieldX) + math.abs(landing.player.fieldZ - ledgeStart.fieldZ),
      2
    )
    assertResident(landing)

    local returned = moveTo(game, facts.newBark)
    assertSeam(game, facts.newBark.mapId, "MAP_NEW_BARK", "Route 29 to New Bark")
    Assert.equal(returned.player.fieldX, facts.newBark.fieldX)
    Assert.equal(returned.player.fieldZ, facts.newBark.fieldZ)
    Assert.equal(game.runtime.physicalCoverage, physicalOwner, "reverse seam must preserve the physical world")
    Assert.equal(game.lifecycle.runtimeDisposals, 0, "the live return must occur before any save/restart")
    assertResident(returned)

    local farSavePosition = moveTo(game, facts.far)
    Assert.equal(farSavePosition.mapId, 33)
    Assert.equal(farSavePosition.player.fieldX, facts.far.fieldX)
    Assert.equal(farSavePosition.player.fieldZ, facts.far.fieldZ)
    assertResident(farSavePosition)
    local saved = game:save()
    local resumed = game:restart({ save = "resume" }):snapshot()
    Assert.equal(resumed.player.fieldX, saved.player.fieldX)
    Assert.equal(resumed.player.fieldZ, saved.player.fieldZ)
    Assert.equal(resumed.player.facing, saved.player.facing)
    Assert.equal(resumed.player.worldY, saved.player.worldY)
    Assert.equal(resumed.mapId, saved.mapId)
    Assert.equal(resumed.coverage.anchorX, saved.coverage.anchorX)
    Assert.equal(resumed.coverage.anchorZ, saved.coverage.anchorZ)
    assertResident(resumed)
    local returnSnapshot = moveTo(game, facts.newBark)
    Assert.equal(returnSnapshot.mapId, facts.newBark.mapId)
    assertResident(returnSnapshot)
    local building = facts.buildingWarp
    moveTo(game, building)
    game:face(building.direction)
    local started = game:advanceUntil("building transition starts", function(snapshot)
      return snapshot.transition.phase ~= "idle"
    end, 32)
    game:advanceUntil("building transition completes", function(snapshot)
      return snapshot.transition.phase == "idle" and snapshot.mapId ~= facts.newBark.mapId
    end, 120)
    local transition = { destination = game:snapshot() }
    Assert.isTrue(transition.destination.mapId ~= facts.newBark.mapId)
    Assert.isTrue(started.transition.phase ~= "idle")
    local interior = game:snapshot()
    Assert.isTrue(interior.mapId ~= facts.newBark.mapId)
    Assert.equal(#interior.terrainEffects.instances, 0)
    uniqueActors(interior)
    Assert.equal(interior.transition.phase, "idle")
  end)
end

return T
