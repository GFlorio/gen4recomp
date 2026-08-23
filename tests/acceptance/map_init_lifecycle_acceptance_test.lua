-- Production-composed map-init lifecycle contracts. Real generated field maps,
-- FieldRuntime, FieldScripts, FieldSession, and the scheduler remain in the
-- path; the acceptance harness supplies only host seams and isolated saves.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldScripts = require("game.src.game.FieldScripts")
local ScriptInteractionClient = require("libs.engine.src.script.ScriptInteractionClient")

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

local function oneShotTypes(runtime)
  local result = {}
  for _, group in ipairs(runtime.runtimeMap.fieldData.initScripts) do
    if group.type ~= "on_frame_eq" then
      result[#result + 1] = group.type
    end
  end
  return result
end

local function installStartRecorder()
  local starts = {}
  local original = assert(ScriptInteractionClient.startInitScript)
  ScriptInteractionClient.startInitScript = function(self, scriptId, tick)
    starts[#starts + 1] = { scriptId = scriptId, tick = tick }
    return original(self, scriptId, tick)
  end
  return starts, function()
    ScriptInteractionClient.startInitScript = original
  end
end

local function lifecycleStartTypes(starts, runtime)
  local lifecycleByScriptId = {}
  for _, group in ipairs(runtime.runtimeMap.fieldData.initScripts) do
    if group.type ~= "on_frame_eq" then
      lifecycleByScriptId[group.scriptId] = group.type
    end
  end
  local result = {}
  for _, start in ipairs(starts) do
    if lifecycleByScriptId[start.scriptId] ~= nil then
      result[#result + 1] = lifecycleByScriptId[start.scriptId]
    end
  end
  return result
end

local function installBoundaryRecorder()
  local events = {}
  local actorEnter = assert(FieldActorManager.enterMap)
  local queueLifecycles = assert(FieldSession.queueMapLifecycles)
  local mapSwap = assert(FieldScripts.onMapSwap)
  FieldActorManager.enterMap = function(self, runtimeMap, eventState)
    events[#events + 1] = { kind = "actors_enter", mapId = runtimeMap.mapId }
    return actorEnter(self, runtimeMap, eventState)
  end
  FieldSession.queueMapLifecycles = function(self, lifecycles)
    for _, lifecycle in ipairs(lifecycles) do
      events[#events + 1] = { kind = "lifecycle_request", lifecycle = lifecycle, mapId = self.currentMap.mapId }
    end
    return queueLifecycles(self, lifecycles)
  end
  FieldScripts.onMapSwap = function(self, player, runtimeMap)
    events[#events + 1] = { kind = "scripts_rebind", mapId = runtimeMap.mapId }
    return mapSwap(self, player, runtimeMap)
  end
  return events,
    function()
      FieldActorManager.enterMap = actorEnter
      FieldSession.queueMapLifecycles = queueLifecycles
      FieldScripts.onMapSwap = mapSwap
    end
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

function T.tests.initial_map_lifecycle_order_precedes_actor_entry_and_reaches_idle_field_play()
  local harness = lifecycleHarness()
  harness:forEachVersion(function(versionId)
    local events, restoreBoundaries = installBoundaryRecorder()
    local starts, restoreStarts = installStartRecorder()
    local game
    local ok, err = xpcall(function()
      game = harness:boot({ versionId = versionId, map = "MAP_ROUTE_22", save = "fresh" })
      Assert.equal(game:snapshot().mapSymbol, "MAP_ROUTE_22")
      local expected = oneShotTypes(game.runtime)
      Assert.isTrue(#expected > 0, "initial map must declare one-shot lifecycle work")
      Assert.equal(events[1].kind, "lifecycle_request", "transition intent must precede actor entry")
      Assert.equal(events[1].lifecycle, "on_transition")
      local actorIndex
      for index, event in ipairs(events) do
        if event.kind == "actors_enter" then
          actorIndex = index
          break
        end
      end
      Assert.isTrue(actorIndex ~= nil, "initial actor entry must be recorded")
      for index = 1, actorIndex - 1 do
        Assert.equal(events[index].kind, "lifecycle_request")
      end
      game:advanceUntil("initial map lifecycle work to finish", function(snapshot)
        return snapshot.transition.phase == "idle"
          and not snapshot.fieldLocked
          and #lifecycleStartTypes(starts, game.runtime) == #expected
      end, 240)
      Assert.deepEqual(lifecycleStartTypes(starts, game.runtime), expected)
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    restoreStarts()
    restoreBoundaries()
    if game then
      game:close()
    end
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.destination_lifecycle_runs_after_bind_and_ordinary_frames_do_not_repeat_events()
  local harness = lifecycleHarness()
  harness:forEachVersion(function(versionId)
    local events, restoreBoundaries = installBoundaryRecorder()
    local restoreStarts = function() end
    local game
    local ok, err = xpcall(function()
      game = harness:boot({ versionId = versionId, map = "MAP_ROUTE_22", save = "fresh" })
      Assert.deepEqual(lifecycleTypes(game.runtime), { "on_transition", "on_resume", "on_frame_eq" })
      local before = game:snapshot()
      game:advanceUntil("initial map lifecycle queue to drain", function(snapshot)
        return not snapshot.fieldLocked and snapshot.player.motion == "idle"
      end, 240)
      for _ = 1, 30 do
        game:step()
      end
      local starts
      starts, restoreStarts = installStartRecorder()
      game:moveTo({ fieldX = 936, fieldZ = 267 })
      game:move("west")
      local transition = game:waitForTransition()
      Assert.isFalse(transition.destination.mapId == before.mapId)
      Assert.equal(game.runtime.scripts.initController.mapId, transition.destination.mapId)
      local expected = oneShotTypes(game.runtime)
      game:advanceUntil("destination one-shot lifecycle queue to drain", function(snapshot)
        return not snapshot.fieldLocked and snapshot.player.motion == "idle"
      end, 240)
      Assert.deepEqual(lifecycleStartTypes(starts, game.runtime), expected)
      local destinationActorIndex
      local destinationRebindIndex
      local destinationRequestIndex
      for index = #events, 1, -1 do
        local event = events[index]
        if
          destinationActorIndex == nil
          and event.kind == "actors_enter"
          and event.mapId == transition.destination.mapId
        then
          destinationActorIndex = index
        elseif
          destinationRebindIndex == nil
          and event.kind == "scripts_rebind"
          and event.mapId == transition.destination.mapId
        then
          destinationRebindIndex = index
        elseif
          destinationRequestIndex == nil
          and event.kind == "lifecycle_request"
          and event.mapId == transition.destination.mapId
        then
          destinationRequestIndex = index
        end
      end
      Assert.isTrue(destinationRebindIndex < destinationRequestIndex)
      Assert.isTrue(destinationRequestIndex < destinationActorIndex)
      local count = #lifecycleStartTypes(starts, game.runtime)
      for _ = 1, 30 do
        game:step()
      end
      Assert.equal(
        #lifecycleStartTypes(starts, game.runtime),
        count,
        "ordinary frames must not repeat event lifecycles"
      )
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    restoreStarts()
    restoreBoundaries()
    if game then
      game:close()
    end
    if not ok then
      error(err, 0)
    end
  end)
end

return T
