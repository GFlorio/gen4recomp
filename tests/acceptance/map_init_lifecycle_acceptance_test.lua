-- Production-composed map-init lifecycle contracts. Real generated field maps,
-- FieldRuntime, FieldScripts, FieldSession, and the scheduler remain in the
-- path; the acceptance harness supplies only host seams and isolated saves.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "map-init", "lifecycle" },
  },
  tests = {},
}

local function lifecycleTypes(runtime)
  local result = {}
  for _, group in ipairs(runtime.runtimeMap.fieldData.initScripts) do
    result[#result + 1] = group.type
  end
  return result
end

local function recordInitStarts(runtime)
  local client = assert(runtime.scripts.client)
  local original = assert(client.startInitScript)
  local lifecycleByScriptId = {}
  for _, group in ipairs(runtime.runtimeMap.fieldData.initScripts) do
    if group.type ~= "on_frame_eq" then
      lifecycleByScriptId[group.scriptId] = group.type
    end
  end
  local starts = {}
  client.startInitScript = function(self, scriptId, tick)
    starts[#starts + 1] = {
      scriptId = scriptId,
      lifecycle = lifecycleByScriptId[scriptId],
      tick = tick,
      mapId = runtime.runtimeMap.mapId,
    }
    return original(self, scriptId, tick)
  end
  return starts, function()
    client.startInitScript = original
  end
end

local function eventStartCount(starts)
  local count = 0
  for _, start in ipairs(starts) do
    if start.lifecycle ~= nil then
      count = count + 1
    end
  end
  return count
end

local function lifecycleHarness()
  local harness = AcceptanceHarness.new()
  local defaultGameFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultGameFactory(versionId, map)
    if map == "MAP_NEW_BARK_ELMS_LAB_1F" then
      -- The shared harness default is a valid overworld fixture, not the
      -- laboratory's compiled walkable surface. Use the center of its plate.
      game.location.fieldX = 4
      game.location.fieldZ = 13
    elseif map == "MAP_ROUTE_22" then
      -- Route 22's compiled map has walkable terrain and open collision at
      -- local tile (9, 9); the shared (6, 6) fixture spawn has no surface.
      game.location.fieldX = 9
      game.location.fieldZ = 9
      game.worldState:setFlag(638)
      game.worldState:setFlag(769)
      game.worldState:setFlag(770)
    end
    return game
  end
  return harness
end

function T.tests.elms_lab_mixed_lifecycle_map_binds_and_reaches_idle_field_play()
  local harness = lifecycleHarness()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = "MAP_NEW_BARK_ELMS_LAB_1F", save = "fresh" })
    local ok, err = xpcall(function()
      Assert.equal(game:snapshot().mapSymbol, "MAP_NEW_BARK_ELMS_LAB_1F")
      Assert.deepEqual(lifecycleTypes(game.runtime), { "on_resume", "on_frame_eq" })
      game:advanceUntil("Elm's Lab initial lifecycle work to finish", function(snapshot)
        return snapshot.transition.phase == "idle" and not snapshot.fieldLocked
      end, 240)
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.destination_lifecycle_runs_after_bind_and_ordinary_frames_do_not_repeat_events()
  local harness = lifecycleHarness()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = "MAP_ROUTE_22", save = "fresh" })
    local ok, err = xpcall(function()
      Assert.deepEqual(lifecycleTypes(game.runtime), { "on_transition", "on_resume", "on_frame_eq" })
      local starts, restore = recordInitStarts(game.runtime)
      local before = game:snapshot()
      game:advanceUntil("initial map lifecycle queue to drain", function(snapshot)
        return not snapshot.fieldLocked and snapshot.player.motion == "idle" and eventStartCount(starts) == 1
      end, 240)
      local initialEventCount = eventStartCount(starts)
      for _ = 1, 30 do
        game:step()
      end
      local finalEventCount = eventStartCount(starts)
      Assert.equal(finalEventCount, initialEventCount, "ordinary frames must not repeat event lifecycles")
      game:moveTo({ fieldX = 936, fieldZ = 267 })
      game:move("west")
      local transition = game:waitForTransition()
      Assert.isFalse(transition.destination.mapId == before.mapId)
      Assert.equal(game.runtime.scripts.initController.mapId, transition.destination.mapId)
      restore()
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
