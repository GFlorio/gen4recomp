-- The production field composition must preserve value evaluation, branch
-- selection, task boundaries, and result publication for script resources.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "runtime" },
  },
  tests = {},
}

local SCRIPT_ID = "acceptance.script_runtime"

local function withGame(versionId, fn)
  local game = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = { acceptanceScripts = AcceptanceScripts },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "script runtime acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.script_execution_preserves_values_conditions_and_task_order()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    withGame(versionId, function(game)
      local started = game:startScript(SCRIPT_ID)
      Assert.isTrue(started.fieldLocked, "a foreground script must own the field while it runs")

      local composed = assert(game.runtime.scripts.composition:effective(SCRIPT_ID))
      local graph = assert(composed.entries[1].graph, "the injected script must compile through production composition")
      local operations = {}
      for _, node in pairs(graph.nodes) do
        operations[node.op] = true
      end
      Assert.isTrue(operations.set_var)
      Assert.isTrue(operations["if"])
      Assert.isTrue(operations.wait_ticks)

      game:advanceUntil("script runtime task boundary", function(snapshot)
        return not snapshot.fieldLocked
      end, 120)

      local world = game.runtime.scripts.worldState
      Assert.equal(world:getVar("VAR_UNK_407C"), 7)
      Assert.equal(world:getVar("VAR_UNK_407D"), 7)
      Assert.equal(world:getVar("VAR_UNK_407F"), 7)
      Assert.isTrue(world:isFlagSet("FLAG_UNK_8A1"), "the evaluated condition must select the true branch")
      Assert.isFalse(world:isFlagSet("FLAG_UNK_8A2"), "the false branch must not run")
    end)
  end)
end

return T
