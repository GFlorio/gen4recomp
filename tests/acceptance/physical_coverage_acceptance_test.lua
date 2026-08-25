-- Production-composed outdoor streaming acceptance. The harness supplies only
-- the host save root and render trap; maps, cache data, collision, and saves
-- remain the production runtime's responsibility.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "streaming", "save" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"

local function farRouteTarget(_)
  -- This is the source-derived Route 29 corridor target. Its far save restore
  -- remains dependent on logical-zone ownership supplied by the next slice.
  return { fieldX = 626, fieldZ = 389 }
end

local function moveToFarRoute(game, snapshot)
  local ok, err = pcall(game.moveTo, game, farRouteTarget(snapshot))
  Assert.isTrue(
    ok,
    "production physical-cell streaming must keep the New Bark-to-Route 29 path navigable: " .. tostring(err)
  )
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
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = TOWN, save = "fresh" })
    local ok, err = xpcall(function()
      local before = game:snapshot()
      local initial = coverageStatus(game)
      assertCoverageBounded(initial)

      local target = farRouteTarget(before)
      moveToFarRoute(game, before)

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
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

-- A settled far position must round-trip through the normal FieldSave path;
-- the acceptance namespace is the only substituted host boundary.
function T.tests.far_streamed_position_save_resume_rebuilds_coverage()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = TOWN, save = "fresh" })
    local ok, err = xpcall(function()
      local before = game:snapshot()
      local target = farRouteTarget(before)
      moveToFarRoute(game, before)
      game:advanceUntil("far streamed movement settles", function(snapshot)
        return snapshot.player.motion == "idle"
      end, 30)
      local saved = game:snapshot()
      local savedCoverage = coverageStatus(game)
      assertCoverageBounded(savedCoverage)
      Assert.equal(saved.player.fieldX, target.fieldX, "far streamed save captured the wrong field X")
      Assert.equal(saved.player.fieldZ, target.fieldZ, "far streamed save captured the wrong field Z")

      local saveOk, saveErr = game.runtime:saveSession("acceptance far streamed position")
      Assert.isTrue(saveOk, "far streamed save must publish after idle settlement: " .. tostring(saveErr))
      local persisted = assert(game.runtime.saveStore:load())
      Assert.equal(persisted.fieldX, target.fieldX, "published save has the wrong field X")
      Assert.equal(persisted.fieldZ, target.fieldZ, "published save has the wrong field Z")
      Assert.equal(game.runtime.session.player.fieldX, target.fieldX, "session save player has the wrong field X")
      Assert.equal(game.runtime.session.player.fieldZ, target.fieldZ, "session save player has the wrong field Z")
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
      Assert.equal(restored.mapSymbol, TOWN)
      Assert.equal(saved.player.fieldX, target.fieldX)
      Assert.equal(saved.player.fieldZ, target.fieldZ)
      Assert.equal(restored.player.fieldX, saved.player.fieldX)
      Assert.equal(restored.player.fieldZ, saved.player.fieldZ)
      Assert.equal(restored.player.worldY, saved.player.worldY)
      Assert.equal(restored.player.surfaceId, saved.player.surfaceId)
      Assert.equal(restoredCoverage.anchorX, savedCoverage.anchorX)
      Assert.equal(restoredCoverage.anchorZ, savedCoverage.anchorZ)
      Assert.equal(restoredCoverage.terrainDependencyHash, savedCoverage.terrainDependencyHash)
      Assert.equal(game:renderAttempts(), 0, "save/resume acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
