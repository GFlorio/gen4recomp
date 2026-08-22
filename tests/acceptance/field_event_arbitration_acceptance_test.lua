-- Production-composed field-event arbitration contracts. These scenarios use
-- ROM-derived maps and events through AcceptanceHarness and stop before draw.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "events", "warps", "interaction" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB_2F = "MAP_NEW_BARK_ELMS_LAB_2F"

local function withGame(map, fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = map, save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function recordsNamed(game, name)
  local records = {}
  for _, record in ipairs(game.hosts.events.records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

local function coordinateAt(game, fieldX, fieldZ)
  for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.coordinates) do
    if
      fieldX >= event.x
      and fieldX < event.x + event.width
      and fieldZ >= event.z
      and fieldZ < event.z + event.height
    then
      return event
    end
  end
  return nil
end

local function setCoordinatePredicate(game, event, matching)
  game:setWorldState({
    variable = event.variableId,
    value = matching and event.requiredValue or event.requiredValue + 1,
  })
end

local function warpCellWithBehavior(game, behavior)
  local map = game.runtime.runtimeMap
  local origin = assert(map.coordinateOrigin)
  for _, warp in ipairs(map.fieldData.events.warps) do
    local localX, localZ = warp.x - origin.x, warp.z - origin.z
    if map.collision:containsLocal(localX, localZ) and map.collision:getLocal(localX, localZ).behavior == behavior then
      return { fieldX = warp.x, fieldZ = warp.z }
    end
  end
  return nil
end

local function backgroundCell(game, eventType)
  local player = game:snapshot().player
  local selected
  local selectedDistance
  for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.background) do
    if event.type == eventType and event.scriptId ~= 0 then
      if event.x == 685 and event.z == 400 then
        return event
      end
      local distance = math.abs(event.x - player.fieldX) + math.abs(event.z + 1 - player.fieldZ)
      if selectedDistance == nil or distance < selectedDistance then
        selected = event
        selectedDistance = distance
      end
    end
  end
  return selected
end

local function actionCellBesidePassiveSign(game)
  local runtime = game.runtime
  for _, event in ipairs(runtime.runtimeMap.fieldData.events.background) do
    if event.type == 1 and event.scriptId ~= 0 then
      local fieldX, fieldZ = event.x, event.z + 1
      local intent = runtime.interactionResolver:resolve({
        runtimeMap = runtime.runtimeMap,
        fieldX = fieldX,
        fieldZ = fieldZ,
        surfaceId = runtime.player.surfaceId,
        worldY = runtime.player.worldY,
        facing = "east",
        tick = runtime.session.tick + 1,
      })
      if intent then
        return { fieldX = fieldX, fieldZ = fieldZ }, intent
      end
    end
  end
  error("New Bark must provide an east-facing Action target beside a type-one sign")
end

local function stepWithDirectionAndAction(game, direction)
  local runtime = game.runtime
  runtime:press(direction)
  runtime:pressAction()
  runtime:update(runtime.session.FIXED_DT)
  runtime:release(direction)
  runtime:releaseAction()
end

local function enterLab2F(game)
  game:moveTo({ fieldX = 688, fieldZ = 392 })
  game:face("west")
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, LAB_2F)
end

function T.tests.coordinate_event_runs_on_the_landing_step()
  withGame(TOWN, function(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, true)
    game:moveTo({ fieldX = 688, fieldZ = 392 })

    local started = recordsNamed(game, "script.started")
    Assert.isTrue(#started > 0, "the landing coordinate script must start during the landing step")
    Assert.equal(started[#started].payload.trigger.kind, "coordinate")
    Assert.equal(game:snapshot().mapSymbol, TOWN, "the landing script owns the step before input warping")
  end)
end

function T.tests.coordinate_priority_and_variable_gate_control_the_landing()
  withGame(TOWN, function(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, true)
    game:moveTo({ fieldX = 688, fieldZ = 392 })
    local matching = recordsNamed(game, "script.started")
    Assert.isTrue(#matching > 0)
    Assert.equal(matching[#matching].payload.trigger.kind, "coordinate")
  end)

  withGame(TOWN, function(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, false)
    game:moveTo({ fieldX = 688, fieldZ = 392 })
    Assert.equal(#recordsNamed(game, "script.started"), 0, "a mismatched coordinate variable must skip the script")
    game:face("west")
    local transition = game:waitForTransition()
    Assert.equal(transition.destination.mapSymbol, LAB_2F)
  end)
end

function T.tests.elm_lab_second_floor_exits_east_through_production_input()
  withGame(TOWN, function(game)
    enterLab2F(game)
    local cell = assert(
      warpCellWithBehavior(game, MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST),
      "Elm Lab 2F must expose its east exit"
    )
    game:moveTo(cell)
    game:step({ direction = "east" })
    Assert.isFalse(game:snapshot().transition.phase == "idle", "the east exit must start from production input")
  end)
end

function T.tests.north_facing_type_one_background_starts_without_action()
  withGame(TOWN, function(game)
    local event = assert(backgroundCell(game, 1), "New Bark must contain a scripted type-one background event")
    game:moveTo({ fieldX = event.x, fieldZ = event.z + 1 })
    local before = #recordsNamed(game, "script.started")
    game:step({ direction = "north" })
    local started = recordsNamed(game, "script.started")
    Assert.isTrue(#started > before, "looking north at a type-one background must start its script")
    Assert.equal(started[#started].payload.trigger.kind, "background")
  end)
end

function T.tests.simultaneous_direction_and_action_preserves_established_facing()
  withGame(TOWN, function(game)
    local cell, actionIntent = actionCellBesidePassiveSign(game)
    game:moveTo(cell)
    game:face("east")
    local before = #recordsNamed(game, "script.started")

    stepWithDirectionAndAction(game, "north")

    local started = recordsNamed(game, "script.started")
    Assert.equal(#started, before + 1, "Action must consume the tick instead of the passive sign")
    Assert.equal(started[#started].payload.trigger.kind, actionIntent.kind)
    Assert.equal(game:snapshot().player.facing, "east", "passive probing must not redirect Action facing")
  end)
end

function T.tests.mid_step_direction_edge_cannot_start_passive_sign()
  withGame(TOWN, function(game)
    local typeOne = assert(backgroundCell(game, 1), "a scripted type-one background event is required")
    game:moveTo({ fieldX = typeOne.x, fieldZ = typeOne.z + 1 })
    game:face("east")
    game:step({ direction = "south" })
    local walking = game:snapshot()
    Assert.equal(walking.player.motion, "walking", "the arbitration setup must enter a real movement step")
    local before = #recordsNamed(game, "script.started")

    game:step({ direction = "north" })

    Assert.equal(#recordsNamed(game, "script.started"), before, "a fresh direction edge must not probe while walking")
    Assert.equal(game:snapshot().player.facing, "east", "the mid-step probe must not change facing")
  end)
end

return T
