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

return T
