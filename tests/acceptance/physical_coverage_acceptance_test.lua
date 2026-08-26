-- Production-composed outdoor streaming acceptance. The harness supplies only
-- the host save root and render trap; maps, cache data, collision, and saves
-- remain the production runtime's responsibility.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "streaming", "save" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local function farRouteTarget(facts)
  return { fieldX = facts.far.fieldX, fieldZ = facts.far.fieldZ }
end

local function moveToFarRoute(game, facts)
  local ok, err = pcall(game.moveTo, game, farRouteTarget(facts))
  Assert.isTrue(
    ok,
    "production physical-cell streaming must keep the New Bark-to-Route 29 path navigable: " .. tostring(err)
  )
end

local function withVersion(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local romFs, err = RomFs.open(versionId)
    assert(romFs, tostring(err))
    local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
    romFs:close()
    local game = harness:boot({ versionId = versionId, map = TOWN, save = "fresh" })
    local ok, failure = xpcall(function()
      fn(game, facts)
    end, debug.traceback)
    game:close()
    if not ok then
      error(failure, 0)
    end
  end)
end

local function coverageStatus(game)
  local runtimeMap = assert(game.runtime.runtimeMap, "production field runtime has no active map")
  local coverage = assert(runtimeMap.coverage, "production outdoor runtime has no physical coverage owner")
  return assert(coverage:status(), "physical coverage status is unavailable")
end

local function assertCoverageBounded(status)
  Assert.isTrue(status.residentCount <= 9, "physical coverage must remain bounded to nine cells")
  Assert.isTrue(status.anchorX ~= nil and status.anchorZ ~= nil, "coverage must expose its matrix anchor")
  Assert.isTrue(type(status.terrainDependencyHash) == "string", "coverage must expose dependency identity")
end

-- A production outdoor session must leave the former New Bark neighborhood and
-- keep resolving real collision, terrain, and cell presentation data.
function T.tests.travel_beyond_new_bark_ring_keeps_production_coverage_valid()
  withVersion(function(game, facts)
    local initial = coverageStatus(game)
    assertCoverageBounded(initial)

    local target = farRouteTarget(facts)
    moveToFarRoute(game, facts)

    local after = game:snapshot()
    local final = coverageStatus(game)
    Assert.equal(after.player.fieldX, target.fieldX)
    Assert.equal(after.player.fieldZ, target.fieldZ)
    Assert.isTrue(
      final.anchorX ~= initial.anchorX or final.anchorZ ~= initial.anchorZ,
      "crossing a physical cell boundary must recenter coverage"
    )
    assertCoverageBounded(final)
    Assert.isTrue(#final.residentCellKeys <= 9, "coverage must expose at most nine resident cell keys")
    Assert.equal(game:renderAttempts(), 0, "streaming acceptance must stop before GPU rendering")
  end)
end

-- A settled far position must round-trip through the normal FieldSave path;
-- the acceptance namespace is the only substituted host boundary.
function T.tests.far_streamed_position_save_resume_rebuilds_coverage()
  withVersion(function(game, facts)
    moveToFarRoute(game, facts)
    game:advanceUntil("far streamed movement settles", function(snapshot)
      return snapshot.player.motion == "idle" and snapshot.transition.phase == "idle"
    end, 30)
    local saved = game:snapshot()
    local savedCoverage = coverageStatus(game)
    assertCoverageBounded(savedCoverage)
    Assert.equal(saved.mapSymbol, "MAP_ROUTE_29")
    Assert.equal(saved.player.fieldX, facts.far.fieldX)
    Assert.equal(saved.player.fieldZ, facts.far.fieldZ)

    local saveOk, saveErr = game.runtime:saveSession("acceptance far streamed position")
    Assert.isTrue(saveOk, "far streamed save must publish after idle settlement: " .. tostring(saveErr))
    local persisted = assert(game.runtime.saveStore:load())
    Assert.equal(persisted.fieldX, saved.player.fieldX, "published save has the wrong field X")
    Assert.equal(persisted.fieldZ, saved.player.fieldZ, "published save has the wrong field Z")
    Assert.equal(game.runtime.session.player.fieldX, saved.player.fieldX, "session save player has the wrong field X")
    Assert.equal(game.runtime.session.player.fieldZ, saved.player.fieldZ, "session save player has the wrong field Z")
    local restartOk, restartErr = xpcall(function()
      game:restart({ save = "resume" })
    end, function(restartError)
      return debug.traceback(tostring(restartError), 2)
    end)
    Assert.isTrue(
      restartOk,
      "resume boot failed; saveStatus="
        .. tostring(game.runtime and game.runtime.saveStatus)
        .. "; error="
        .. tostring(restartErr)
    )
    Assert.equal(
      game.runtime.saveStatus,
      "Resumed saved field session",
      "position-centered restore was rejected: " .. tostring(game.runtime.saveStatus)
    )

    local restored = game:snapshot()
    local restoredCoverage = coverageStatus(game)
    Assert.equal(restored.mapSymbol, "MAP_ROUTE_29")
    Assert.equal(restored.player.fieldX, facts.far.fieldX)
    Assert.equal(restored.player.fieldZ, facts.far.fieldZ)
    Assert.equal(restored.player.fieldX, saved.player.fieldX)
    Assert.equal(restored.player.fieldZ, saved.player.fieldZ)
    Assert.equal(restored.player.worldY, saved.player.worldY)
    Assert.equal(restored.player.surfaceId, saved.player.surfaceId)
    Assert.equal(restoredCoverage.anchorX, savedCoverage.anchorX)
    Assert.equal(restoredCoverage.anchorZ, savedCoverage.anchorZ)
    Assert.equal(restoredCoverage.terrainDependencyHash, savedCoverage.terrainDependencyHash)
    Assert.equal(game:renderAttempts(), 0, "save/resume acceptance must stop before GPU rendering")
  end)
end

return T
