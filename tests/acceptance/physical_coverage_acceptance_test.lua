-- Production-composed outdoor streaming acceptance. The harness supplies only
-- the host save root and render trap; maps, cache data, collision, and saves
-- remain the production runtime's responsibility.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

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
    OpeningLifecycle.seedNewBarkWestExitScene(game)
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

return T
