-- Production-composed field boot contract. It is ROM-gated because the game
-- must load the normal derived cache, but it stops at the runtime boundary
-- before any presentation or GPU work.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "boot" },
  },
  tests = {},
}

local function requireGameCapability(game, name)
  Assert.isTrue(
    type(game[name]) == "function",
    "acceptance harness must expose " .. name .. " for the production boot contract"
  )
end

function T.tests.production_field_boot_is_idle_controllable_and_never_renders()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({
      versionId = versionId,
      map = "MAP_NEW_BARK_ELMS_LAB_1F",
      save = "fresh",
    })
    local ok, err = xpcall(function()
      local snapshot = game:snapshot()
      Assert.equal(snapshot.versionId, versionId)
      Assert.equal(snapshot.mapSymbol, "MAP_NEW_BARK_ELMS_LAB_1F")
      Assert.equal(snapshot.player.motion, "idle")
      Assert.isFalse(snapshot.dialogue.modal)
      Assert.isFalse(snapshot.fieldLocked)

      game:move("north")
      game:advanceUntil("movement completes", function(state)
        return state.player.motion == "idle" and state.player.facing == "north"
      end, 120)
      Assert.equal(game:renderAttempts(), 0, "acceptance runtime must not construct or draw GPU resources")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

-- BOOT-02: explicit semantic targets must use exactly the same production
-- runtime composition as the default fresh boot.
function T.tests.explicit_semantic_target_boots_through_the_production_runtime()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({
      versionId = versionId,
      map = "MAP_NEW_BARK",
      save = "fresh",
    })
    local ok, err = xpcall(function()
      local snapshot = game:snapshot()
      Assert.equal(snapshot.versionId, versionId)
      Assert.equal(snapshot.mapSymbol, "MAP_NEW_BARK")
      Assert.equal(snapshot.player.motion, "idle")
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

-- BOOT-03/BOOT-04: the app-facing boot decision is acceptance-visible. The
-- harness owns this adapter so tests can select real ready caches without
-- constructing FieldState or any presentation object.
function T.tests.app_boot_decision_selects_the_only_ready_version_runtime()
  local harness = AcceptanceHarness.new()
  requireGameCapability(harness, "bootSelected")
  local game = harness:bootSelected({ versions = { "heartgold" }, save = "fresh" })
  local ok, err = xpcall(function()
    Assert.equal(game:snapshot().versionId, "heartgold")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.app_boot_decision_exposes_selection_when_two_versions_are_ready()
  local harness = AcceptanceHarness.new()
  requireGameCapability(harness, "selectVersion")
  local selection = harness:selectVersion({ "heartgold", "soulsilver" })
  Assert.deepEqual(selection:versions(), { "heartgold", "soulsilver" })
  local game = selection:choose("heartgold")
  local ok, err = xpcall(function()
    Assert.equal(game:snapshot().versionId, "heartgold")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- BOOT-05: a boot failure is actionable and must clean up the isolated save
-- namespace/runtime resources it acquired before the malformed artifact was
-- detected. The harness exposes this as a scoped fault-injection boundary.
function T.tests.corrupt_required_artifact_fails_actionably_and_releases_boot_resources()
  local harness = AcceptanceHarness.new()
  requireGameCapability(harness, "bootWithCorruptArtifact")
  local result = harness:bootWithCorruptArtifact("heartgold", "world")
  Assert.isTrue(result.error:find("world", 1, true) ~= nil)
  Assert.equal(result.disposeCount, 1)
end

return T
