-- Production-composed map-entry contracts. Real generated maps, FieldRuntime,
-- FieldScripts, FieldSession, and the scheduler remain in the path; the
-- acceptance harness supplies only host seams and isolated saves.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldRuntime = require("game.src.game.FieldRuntime")
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
    if group.type ~= "on_frame_eq" then
      result[#result + 1] = group.type
    end
  end
  return result
end

local function installExecutionRecorder()
  local starts = {}
  local actorEntries = {}
  local events = {}
  local originalStart = assert(ScriptInteractionClient.startInitScript)
  local originalEnter = assert(FieldActorManager.enterMap)
  local originalInstantiate = assert(FieldActorManager._instantiate)
  local originalPrepare = assert(FieldRuntime._prepareSwap)
  local originalCommit = assert(FieldRuntime._commitSwap)
  ---@param self ScriptInteractionClient
  ---@param scriptId string
  ---@param tick integer
  ---@return boolean
  ScriptInteractionClient.startInitScript = function(self, scriptId, tick)
    starts[#starts + 1] = { scriptId = scriptId, tick = tick }
    events[#events + 1] = { kind = "script", scriptId = scriptId }
    return originalStart(self, scriptId, tick)
  end
  ---@param self FieldActorManager
  ---@param runtimeMap RuntimeFieldMap
  ---@param eventState FieldEventState
  ---@return nil
  FieldActorManager.enterMap = function(self, runtimeMap, eventState)
    actorEntries[#actorEntries + 1] = { mapId = runtimeMap.mapId }
    events[#events + 1] = { kind = "actors", mapId = runtimeMap.mapId }
    return originalEnter(self, runtimeMap, eventState)
  end
  -- The activation-order invariant is about actual object construction, not
  -- merely the later `enterMap` publication call: a residency path that
  -- still constructs actors ahead of the recorded lifecycle would otherwise
  -- report correct ordering while construction had already occurred.
  ---@param self FieldActorManager
  ---@param entry FieldActorManager.Entry
  ---@param event FieldActorEvent
  ---@param eventState FieldEventState
  ---@return table
  FieldActorManager._instantiate = function(self, entry, event, eventState)
    events[#events + 1] = { kind = "instantiate", mapId = entry.runtimeMap.mapId }
    return originalInstantiate(self, entry, event, eventState)
  end
  FieldRuntime._prepareSwap = function(self, resolution, facing)
    events[#events + 1] = { kind = "prepare" }
    local prepared = originalPrepare(self, resolution, facing)
    events[#events + 1] = { kind = "prepare_done" }
    return prepared
  end
  FieldRuntime._commitSwap = function(self, resolution, facing, prepared)
    events[#events + 1] = { kind = "commit" }
    return originalCommit(self, resolution, facing, prepared)
  end
  return starts,
    actorEntries,
    events,
    function()
      ScriptInteractionClient.startInitScript = originalStart
      FieldActorManager.enterMap = originalEnter
      FieldActorManager._instantiate = originalInstantiate
      FieldRuntime._prepareSwap = originalPrepare
      FieldRuntime._commitSwap = originalCommit
    end
end

local function lifecycleHarness()
  local harness = AcceptanceHarness.new()
  local defaultGameFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultGameFactory(versionId, map)
    if map == "MAP_NEW_BARK_ELMS_LAB_1F" then
      game.location.fieldX = 4
      game.location.fieldZ = 13
    elseif map == "MAP_ROUTE_22" then
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

local function advanceToEntryReady(game, starts)
  local expectedCount = #lifecycleTypes(game.runtime)
  return game:advanceUntil("map entry ready", function(snapshot)
    return #starts >= expectedCount and not snapshot.fieldLocked and snapshot.player.motion == "idle"
  end, 240)
end

local function scriptTypeById(runtime)
  local result = {}
  for _, group in ipairs(runtime.runtimeMap.fieldData.initScripts) do
    if group.scriptId ~= nil then
      result[group.scriptId] = group.type
    end
  end
  return result
end

function T.tests.initial_entry_executes_transition_before_actor_construction()
  local harness = lifecycleHarness()
  harness:forEachVersion(function(versionId)
    local starts, entries, events, restore = installExecutionRecorder()
    local game
    local ok, err = xpcall(function()
      game = harness:boot({ versionId = versionId, map = "MAP_ROUTE_22", save = "fresh" })
      game:advanceUntil("initial actors entered", function()
        return entries[1] ~= nil
      end, 240)
      local types = scriptTypeById(game.runtime)
      Assert.isTrue(#lifecycleTypes(game.runtime) > 0)
      Assert.isTrue(#starts > 0, "entry must execute a lifecycle script")
      Assert.equal(types[starts[1].scriptId], "on_transition")
      Assert.equal(entries[1].mapId, game.runtime.runtimeMap.mapId)
      Assert.isTrue(starts[1].tick < game.runtime.session.tick, "actor entry must follow transition execution")
      local firstScriptIndex, firstConstructionIndex
      for index, event in ipairs(events) do
        if event.kind == "script" and firstScriptIndex == nil then
          firstScriptIndex = index
        elseif event.kind == "instantiate" and firstConstructionIndex == nil then
          firstConstructionIndex = index
        end
      end
      Assert.isTrue(firstScriptIndex ~= nil, "the initial entry must start its transition lifecycle")
      Assert.isTrue(
        firstConstructionIndex == nil or firstScriptIndex < firstConstructionIndex,
        "no object may be constructed before the initial map's on_transition lifecycle starts"
      )
      advanceToEntryReady(game, starts)
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    restore()
    if game then
      game:close()
    end
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.destination_entry_executes_transition_before_destination_actors()
  local harness = lifecycleHarness()
  harness:forEachVersion(function(versionId)
    local starts, entries, events, restore = installExecutionRecorder()
    local game
    local ok, err = xpcall(function()
      game = harness:boot({ versionId = versionId, map = "MAP_ROUTE_22", save = "fresh" })
      advanceToEntryReady(game, starts)
      local before = game:snapshot().mapId
      game:moveTo({ fieldX = 936, fieldZ = 267 })
      local result = game:move("west")
      result = game:waitForTransition()
      Assert.isFalse(result.destination.mapId == before)
      local destination = result.destination.mapId
      game:advanceUntil("destination actors entered", function()
        for _, entry in ipairs(entries) do
          if entry.mapId == destination then
            return true
          end
        end
        return false
      end, 240)
      local destinationEntry
      for index = #entries, 1, -1 do
        if entries[index].mapId == destination then
          destinationEntry = index
          break
        end
      end
      Assert.isTrue(destinationEntry ~= nil, "destination actors must be constructed")
      game:advanceUntil("destination entry lifecycle complete", function(snapshot)
        return game.runtime.session.mapEntryStage == nil
          and not snapshot.fieldLocked
          and snapshot.player.motion == "idle"
      end, 240)
      local destinationActorEvent
      local destinationTransitionEvent
      local destinationCommitEvent
      local destinationPrepareEvent
      for index, event in ipairs(events) do
        if event.kind == "prepare" then
          destinationPrepareEvent = index
        end
        if event.kind == "actors" and event.mapId == destination then
          destinationActorEvent = index
        elseif
          destinationTransitionEvent == nil
          and destinationPrepareEvent ~= nil
          and index > destinationPrepareEvent
          and event.kind == "script"
        then
          destinationTransitionEvent = index
        elseif event.kind == "commit" then
          destinationCommitEvent = index
        end
      end
      Assert.isTrue(destinationCommitEvent ~= nil, "destination ownership must commit before actors enter")
      local eventDescriptions = {}
      for _, event in ipairs(events) do
        eventDescriptions[#eventDescriptions + 1] = event.kind .. ":" .. tostring(event.mapId or "")
      end
      Assert.isTrue(
        destinationTransitionEvent ~= nil,
        "destination transition script must start; " .. table.concat(eventDescriptions, ",")
      )
      Assert.isTrue(destinationActorEvent ~= nil, "destination actors must enter")
      Assert.isTrue(destinationTransitionEvent < destinationActorEvent)
      Assert.isTrue(destinationCommitEvent < destinationActorEvent)

      -- The activation-order invariant is about actual construction, not
      -- merely the later `enterMap` publication call: no destination object
      -- may be constructed before the destination's own on_transition start.
      local firstDestinationConstructionEvent
      for index, event in ipairs(events) do
        if event.kind == "instantiate" and event.mapId == destination then
          firstDestinationConstructionEvent = index
          break
        end
      end
      Assert.isTrue(
        firstDestinationConstructionEvent ~= nil and destinationTransitionEvent < firstDestinationConstructionEvent,
        "no destination object may be constructed before the destination's on_transition lifecycle starts; "
          .. table.concat(eventDescriptions, ",")
      )
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    restore()
    if game then
      game:close()
    end
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.headless_entry_reaches_ready_without_rendering_and_does_not_repeat_lifecycles()
  local harness = lifecycleHarness()
  harness:forEachVersion(function(versionId)
    local starts, _, _, restore = installExecutionRecorder()
    local game
    local ok, err = xpcall(function()
      game = harness:boot({ versionId = versionId, map = "MAP_ROUTE_22", save = "fresh" })
      local expected = lifecycleTypes(game.runtime)
      advanceToEntryReady(game, starts)
      local types = scriptTypeById(game.runtime)
      local actual = {}
      for _, start in ipairs(starts) do
        if types[start.scriptId] ~= nil then
          actual[#actual + 1] = types[start.scriptId]
        end
      end
      Assert.deepEqual(actual, expected)
      local count = #starts
      for _ = 1, 30 do
        game:step()
      end
      Assert.equal(#starts, count, "ordinary field ticks must not restart entry lifecycles")
      Assert.equal(game:renderAttempts(), 0, "headless entry must acknowledge presentation without drawing")
    end, debug.traceback)
    restore()
    if game then
      game:close()
    end
    if not ok then
      error(err, 0)
    end
  end)
end

return T
