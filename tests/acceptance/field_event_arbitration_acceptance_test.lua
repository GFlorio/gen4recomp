-- Production-composed field-event arbitration contracts. These scenarios use
-- ROM-derived maps and events through AcceptanceHarness and stop before draw.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
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
local VAR_UNK_407C = FieldScriptSymbols.variablesByName.VAR_UNK_407C

local function withGame(map, fn, fieldOptions)
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
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
  for _, record in ipairs(game:hostEvents().records) do
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

function T.tests.default_town_spawn_is_passable_in_the_generated_collision()
  withGame(TOWN, function(game)
    local player = game:snapshot().player
    local map = game.runtime.runtimeMap
    local origin = assert(map.coordinateOrigin)
    local localX, localZ = player.fieldX - origin.x, player.fieldZ - origin.z

    Assert.deepEqual({ player.fieldX, player.fieldZ }, { 682, 394 })
    Assert.isFalse(map.collision:isBlockedLocal(localX, localZ), "default town spawn must be passable")
    Assert.isFalse(map.collision:isBlockedLocal(localX, localZ + 1), "default town spawn must have a south exit")
    Assert.isFalse(map.collision:isBlockedLocal(localX + 1, localZ), "default town spawn must have an east exit")
  end)
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

function T.tests.literal_east_then_north_route_advances_each_production_move()
  withGame(TOWN, function(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, true)
    local snapshots = FieldMovement.productionRoute(game, {
      "east",
      "east",
      "east",
      "east",
      "east",
      "east",
      "north",
      "north",
    })

    Assert.equal(#snapshots, 8)
    for index = 1, 6 do
      Assert.deepEqual(
        { snapshots[index].player.fieldX, snapshots[index].player.fieldZ },
        { 682 + index, 394 },
        "east production move " .. tostring(index) .. " must advance"
      )
    end
    Assert.deepEqual({ snapshots[7].player.fieldX, snapshots[7].player.fieldZ }, { 688, 393 })
    Assert.deepEqual({ snapshots[8].player.fieldX, snapshots[8].player.fieldZ }, { 688, 392 })
    Assert.equal(snapshots[8].mapSymbol, TOWN)
  end)
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

local function enterLab2F(game)
  local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
  setCoordinatePredicate(game, event, true)
  FieldMovement.activate(game, { fieldX = event.x, fieldZ = event.z }, "north")
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, LAB_2F)
end

function T.tests.walking_onto_elm_lab_enters_the_second_floor_without_a_turn()
  withGame(TOWN, function(game)
    Assert.isNil(game.runtime.scriptHosts, "the automatic Elm route must use the production-like composition")
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, true)
    game:moveTo({ fieldX = 688, fieldZ = 393 })
    local before = game:snapshot()
    Assert.deepEqual({ before.player.fieldX, before.player.fieldZ }, { 688, 393 })

    game:move("north")
    local screenFadeDirections = {}
    game:advanceUntil("Elm Lab automatic route completes", function(snapshot)
      if snapshot.screenFade and snapshot.screenFade.active then
        screenFadeDirections[snapshot.screenFade.direction] = true
      end
      return snapshot.mapSymbol == LAB_2F and snapshot.transition.phase == "idle" and not snapshot.fieldLocked
    end, 120)
    local destination = game:snapshot()
    Assert.equal(destination.mapSymbol, LAB_2F)
    Assert.deepEqual({ destination.player.fieldX, destination.player.fieldZ }, { 12, 6 })
    Assert.equal(destination.player.facing, "west")
    Assert.isFalse(destination.fieldLocked, "the completed route must release script ownership")
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_UNK_407C), 1)

    -- The Elm route is covered by the source-authored script screen fade, not
    -- an ordinary FieldTransition fade pair (source `FadeScreen -> WaitFade ->
    -- Warp -> FadeScreen -> WaitFade`).
    Assert.isTrue(screenFadeDirections["out"], "the route must use the production script screen fade-out")
    Assert.isTrue(screenFadeDirections["in"], "the route must use the production script screen fade-in")
    Assert.isTrue(
      destination.screenFade == nil or destination.screenFade.completed,
      "the final script screen fade must be clear at the settled destination"
    )
  end, { audioOutput = FakeAudioOutput.new() })
end

function T.tests.coordinate_priority_and_variable_gate_control_the_landing()
  withGame(TOWN, function(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, true)
    FieldMovement.activate(game, { fieldX = event.x, fieldZ = event.z }, "north")
    local matching = recordsNamed(game, "script.started")
    Assert.isTrue(#matching > 0)
    Assert.equal(matching[#matching].payload.trigger.kind, "coordinate")
  end, { recordingScriptHosts = true })

  withGame(TOWN, function(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, false)
    local startsBeforeStep = #recordsNamed(game, "script.started")
    FieldMovement.activate(game, { fieldX = event.x, fieldZ = event.z }, "north")
    Assert.equal(
      #recordsNamed(game, "script.started"),
      startsBeforeStep,
      "a mismatched coordinate variable must skip the script"
    )
    Assert.equal(game:snapshot().mapSymbol, TOWN)
  end, { recordingScriptHosts = true })
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
  end, { recordingScriptHosts = true })
end

function T.tests.elm_lab_second_floor_exit_uses_the_standing_directional_trigger()
  withGame(TOWN, function(game)
    enterLab2F(game)
    local cell = assert(
      warpCellWithBehavior(game, MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST),
      "Elm Lab 2F must expose its east exit"
    )
    game:moveTo(cell)
    game:step({ direction = "east" })
    Assert.isFalse(game:snapshot().transition.phase == "idle")
  end, { audioOutput = FakeAudioOutput.new() })
end

function T.tests.passive_script_handoff_settles_the_player_visual()
  withGame(TOWN, function(game)
    local typeOne = assert(backgroundCell(game, 1), "a scripted type-one background event is required")
    game:moveTo({ fieldX = typeOne.x, fieldZ = typeOne.z + 2 })
    game.runtime.player.facing = "north"
    game:step({ direction = "north" })

    local handoff = game:advanceUntil("passive interaction ownership", function(snapshot)
      return snapshot.player.fieldX == typeOne.x and snapshot.player.fieldZ == typeOne.z + 1 and snapshot.fieldLocked
    end, 120)
    Assert.equal(handoff.playerVisual.pose, "idle")
    Assert.equal(handoff.playerVisual.poseTick, 0)

    local function sample()
      return {
        player = game.runtime.player:renderPosition(0),
        camera = game.runtime.camera:view(0),
      }
    end
    local first = sample()
    for _, alpha in ipairs({ 0.5, 1 }) do
      Assert.deepEqual(game.runtime.player:renderPosition(alpha), first.player)
      Assert.deepEqual(game.runtime.camera:view(alpha), first.camera)
    end
    Assert.deepEqual(first.player, {
      x = game.runtime.player.worldX,
      y = game.runtime.player.worldY,
      z = game.runtime.player.worldZ,
    })

    game:step()
    game:step()
    game:step()
    game:step()
    local later = sample()
    Assert.deepEqual(later.player, first.player)
    Assert.deepEqual(later.camera, first.camera)
  end, { recordingScriptHosts = true })
end

function T.tests.continuous_walking_carries_visual_gait_across_tile_commits()
  withGame(TOWN, function(game)
    game:moveTo({ fieldX = 688, fieldZ = 393 })
    game:move("south")
    local first = game:advanceUntil("first ordinary step", function(snapshot)
      return snapshot.player.motion == "idle" and snapshot.player.fieldZ == 394
    end, 120)
    Assert.equal(first.playerVisual.pose, "walk")
    Assert.isTrue(first.playerVisual.poseTick > 0)

    game:move("south")
    local second = game:advanceUntil("second ordinary step", function(snapshot)
      return snapshot.player.motion == "idle" and snapshot.player.fieldZ == 395
    end, 120)
    Assert.equal(second.playerVisual.pose, "walk")
    Assert.isTrue(second.playerVisual.poseTick > first.playerVisual.poseTick)
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
    local establishedFacing = walking.player.facing

    game:step({ direction = "north" })

    Assert.equal(#recordsNamed(game, "script.started"), before, "a fresh direction edge must not probe while walking")
    Assert.equal(game:snapshot().player.facing, establishedFacing, "the mid-step probe must not change facing")
  end, { recordingScriptHosts = true })
end

return T
