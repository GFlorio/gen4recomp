-- Production-composed simulation contract. The fixed tick runs through the
-- real FieldRuntime and FieldSession while the acceptance harness stops before
-- presentation and GPU work.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "simulation", "coverage" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

-- A fixed simulation tick must not invoke the presentation-only coverage
-- planner. The absence of a coverage plan is the production-visible result of
-- keeping that callback out of FieldSession; no planner or runtime fake is
-- injected into the acceptance composition.
function T.tests.fixed_tick_does_not_invoke_presentation_coverage_planning()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = MAP, save = "fresh" })
    local ok, err = xpcall(function()
      game:step()
      Assert.isNil(
        game.runtime.runtimeMap.coveragePlan,
        "a fixed simulation tick must not create a presentation coverage plan"
      )
      Assert.equal(game:renderAttempts(), 0, "acceptance simulation must stop before GPU presentation")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
