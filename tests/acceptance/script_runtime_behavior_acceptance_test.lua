-- The production field composition must preserve value evaluation, branch
-- selection, task boundaries, and result publication for script resources.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local Script = require("gen4.script")

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
    fieldOptions = { acceptanceScripts = AcceptanceScripts, recordingScriptHosts = true },
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
      Assert.equal(Script.apiVersion, 1, "the public gen4.script facade must retain API version 1")
      local started = game:startScript(SCRIPT_ID)
      Assert.isTrue(started.fieldLocked, "a foreground script must own the field while it runs")

      local starts = game:recordsForScript(SCRIPT_ID)
      Assert.equal(#starts, 1, "the public script must start exactly once")
      local instanceId = starts[1].payload.instanceId

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

      local waitTask
      for _, record in ipairs(game:recordsNamed("script.task_started")) do
        if record.payload.instanceId == instanceId and record.payload.taskType == "wait_ticks" then
          waitTask = record.payload
        end
      end
      Assert.notNil(waitTask, "the composed script must dispatch its blocking wait through the task registry")
      Assert.equal(waitTask.taskVersion, 1, "the wait task serialized version must remain compatible")

      local ended = game:recordsForScript(SCRIPT_ID, "script.ended")
      Assert.equal(#ended, 1, "the composed script must publish one terminal result")
      Assert.isTrue(ended[1].payload.completed, "the composed script must complete without a runtime fault")
    end)
  end)
end

function T.tests.injected_scripts_survive_capture_and_restart()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    withGame(versionId, function(game)
      game:waitForFieldReady()
      game:startScript(SCRIPT_ID)
      game:advanceUntil("injected script completion before restart", function(snapshot)
        return not snapshot.fieldLocked
      end, 120)
      game:waitForFieldReady()

      game:restart()
      local resumed = game:waitForFieldReady()
      Assert.equal(resumed.versionId, versionId, "restart must preserve the selected HGSS version")
      Assert.equal(resumed.mapSymbol, "MAP_NEW_BARK", "restart must restore the captured field map")
      Assert.isNil(game.runtime.errorText, "restart must leave the field runtime usable")
    end)
  end)
end

return T
