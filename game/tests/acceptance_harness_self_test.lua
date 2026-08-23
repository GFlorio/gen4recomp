-- Acceptance-harness component contract. Synthetic runtimes keep the harness
-- mechanics fast and deterministic; ROM-backed flows belong in the companion
-- acceptance suite below.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = { tags = { "acceptance-harness" } },
  tests = {},
}

local function fakeRuntime(versionId)
  local runtime = {
    versionId = versionId,
    session = { tick = 0 },
    player = { fieldX = 4, fieldZ = 7, facing = "south", motion = "idle" },
    runtimeMap = { mapId = 12, mapSymbol = "MAP_TEST" },
    transition = { phase = "idle" },
    disposeCalls = 0,
  }
  function runtime:update()
    self.session.tick = self.session.tick + 1
  end
  function runtime:press(direction)
    self.player.facing = direction
  end
  function runtime:release() end
  function runtime:dispose()
    self.disposeCalls = self.disposeCalls + 1
  end
  return runtime
end

function T.tests.synthetic_boot_is_closed_once_and_uses_a_unique_save_namespace()
  local deleted = {}
  local runtimes = {}
  local graphics = love.graphics
  local originalShader = graphics.newShader
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(versionId)
      local runtime = fakeRuntime(versionId)
      runtimes[#runtimes + 1] = runtime
      return runtime
    end,
    saveNamespace = function(versionId, serial)
      return "acceptance-test/" .. versionId .. "/" .. serial
    end,
    removeSaveNamespace = function(path)
      deleted[#deleted + 1] = path
    end,
  })

  local first = harness:boot({ versionId = "heartgold", save = "fresh" })
  local second = harness:boot({ versionId = "heartgold", save = "fresh" })
  Assert.isTrue(first.saveNamespace ~= second.saveNamespace, "each boot needs an isolated save namespace")
  first:close()
  first:close()
  second:close()
  Assert.equal(runtimes[1].disposeCalls, 1)
  Assert.equal(runtimes[2].disposeCalls, 1)
  Assert.deepEqual(deleted, { first.saveNamespace, second.saveNamespace })
  -- Each boot installs a render trap over the process-global graphics
  -- namespace; a second boot captures the trapped functions as its
  -- "originals", so any close order must still restore the real functions.
  Assert.equal(graphics.newShader, originalShader, "closing every game restores the graphics namespace")
end

function T.tests.advance_until_timeout_contains_a_bounded_semantic_trace()
  local harness = AcceptanceHarness.new({ versions = { "heartgold" }, runtimeFactory = fakeRuntime })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })
  local err = Assert.throws(function()
    game:advanceUntil("impossible state", function()
      return false
    end, 3)
  end)
  local message = tostring(err)
  Assert.isTrue(message:find("impossible state", 1, true) ~= nil)
  Assert.isTrue(message:find("tick", 1, true) ~= nil, "timeout must include snapshot diagnostics")
  Assert.isTrue(#game:trace() <= 3, "the failure trace must stay bounded")
  game:close()
end

function T.tests.wait_for_transition_waits_for_script_ownership_release()
  local lockTicks = 0
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(versionId)
      local runtime = fakeRuntime(versionId)
      runtime.scripts = {
        scheduler = {
          playerMovementLocked = function()
            return lockTicks < 4
          end,
        },
      }
      function runtime:update()
        lockTicks = lockTicks + 1
        self.session.tick = lockTicks
        if lockTicks == 2 then
          self.runtimeMap.mapId = 13
          self.runtimeMap.mapSymbol = "MAP_DESTINATION"
        end
      end
      return runtime
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })
  game:step()

  local transition = game:waitForTransition()

  Assert.equal(transition.destination.mapSymbol, "MAP_DESTINATION")
  Assert.isFalse(transition.destination.fieldLocked)
  Assert.equal(transition.destination.tick, 4)
  game:close()
end

function T.tests.failed_boot_disposes_the_partial_runtime_and_removes_its_namespace()
  local deleted = {}
  local runtime = fakeRuntime("heartgold")
  runtime.session = nil
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function()
      return runtime
    end,
    saveNamespace = function()
      return "acceptance-test/heartgold/failed-boot"
    end,
    removeSaveNamespace = function(path)
      deleted[#deleted + 1] = path
    end,
  })

  Assert.throws(function()
    harness:boot({ versionId = "heartgold", save = "fresh" })
  end)
  Assert.equal(runtime.disposeCalls, 1)
  Assert.deepEqual(deleted, { "acceptance-test/heartgold/failed-boot" })
end

function T.tests.failed_namespace_cleanup_can_be_retried_without_disposing_twice()
  local runtime = fakeRuntime("heartgold")
  local removals = 0
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function()
      return runtime
    end,
    removeSaveNamespace = function()
      removals = removals + 1
      if removals == 1 then
        error("injected namespace cleanup failure")
      end
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })

  Assert.throws(function()
    game:close()
  end)
  game:close()
  Assert.equal(runtime.disposeCalls, 1)
  Assert.equal(removals, 2)
end

function T.tests.selected_versions_are_iterated_in_declared_order()
  local harness = AcceptanceHarness.new({
    versions = { "heartgold", "soulsilver" },
    runtimeFactory = fakeRuntime,
  })
  local seen = {}
  harness:forEachVersion(function(versionId)
    seen[#seen + 1] = versionId
  end)
  Assert.deepEqual(seen, { "heartgold", "soulsilver" })
end

function T.tests.restart_reuses_the_save_namespace_and_disposes_the_replaced_runtime_once()
  local runtimes = {}
  local optionsSeen = {}
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(versionId, _, options)
      optionsSeen[#optionsSeen + 1] = options
      local runtime = fakeRuntime(versionId)
      runtimes[#runtimes + 1] = runtime
      return runtime
    end,
    saveNamespace = function()
      return "acceptance-test/heartgold/restart"
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })

  local resumed = game:restart({ save = "resume" })

  Assert.equal(resumed, game)
  Assert.equal(runtimes[1].disposeCalls, 1)
  Assert.isTrue(optionsSeen[2].resumeSave)
  Assert.isFalse(optionsSeen[2].resetSave)
  game:close()
  Assert.equal(runtimes[2].disposeCalls, 1)
end

function T.tests.restart_reuses_the_original_field_options()
  local optionsSeen = {}
  local fieldOptions = {
    viewportWidth = 1280,
    viewportHeight = 720,
    screenTopology = { id = "dual-display" },
  }
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(versionId, _, options)
      optionsSeen[#optionsSeen + 1] = options
      return fakeRuntime(versionId)
    end,
  })
  local game = harness:boot({
    versionId = "heartgold",
    save = "fresh",
    fieldOptions = fieldOptions,
  })

  game:restart({ save = "resume" })

  Assert.equal(optionsSeen[2].viewportWidth, 1280)
  Assert.equal(optionsSeen[2].viewportHeight, 720)
  Assert.equal(optionsSeen[2].screenTopology, fieldOptions.screenTopology)
  game:close()
end

return T
