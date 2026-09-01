-- Production-composed contracts for the Player House 1F Mom opening scene,
-- its New Bark friend/Marill follow-up, lifecycle arbitration under a
-- faulted foreground owner, and the Start Menu policy bridge. Real
-- ROM-derived maps, scripts, and the scheduler stay in the path; only host
-- boundaries (audio, script effect/event recording) are faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local FieldActorEmoteRenderer = require("libs.hgss.src.presentation.FieldActorEmoteRenderer")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local SurfaceResolver = require("libs.hgss.src.field.SurfaceResolver")
local StartMenuPolicy = require("libs.hgss.src.ui.StartMenuPolicy")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "lifecycle", "opening", "start-menu" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }
local VAR_SCENE_PLAYERS_HOUSE_1F = OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F
local FLAG_HIDE_NEW_BARK_FRIEND = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND
local FLAG_HIDE_NEW_BARK_MARILL = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_MARILL

local function emotePool()
  return {
    build = function(_, fn)
      return fn()
    end,
    meshFor = function()
      return { mesh = {}, center = { 0, 0, 0 } }
    end,
    imageFor = function()
      return {}
    end,
  }
end

local function withGame(map, fn, fieldOptions)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "opening-lifecycle acceptance must stop before GPU rendering")
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

-- Enter Player House 1F through the real production town door, exactly as
-- an ordinary player would.
local function enterHouse(game)
  game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
end

-- Repeatedly press-and-release within the same tick, retrying until the
-- application host observes the edge; a single upfront press can be
-- discarded while the map-entry lifecycle still owns input.
local function openMenu(game)
  game:waitForFieldEntry()
  for _ = 1, 60 do
    local status = game.runtime.applicationHost:status()
    if status.menu then
      return status.menu
    end
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
  end
  error("the start menu did not open")
end

local function closeMenu(game)
  for _ = 1, 60 do
    local status = game.runtime.applicationHost:status()
    if not status.menu then
      return
    end
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
  end
  error("the start menu did not close")
end

local function actionById(menu, id)
  for _, action in ipairs(menu.actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

-- The exact source facts FieldRuntime itself reads to compose the Start
-- Menu (game/hgss/src/field/FieldRuntime.lua:_composeStartMenu). Reused here only
-- to observe the pure source-enablement gate directly: the application
-- host's composed `enabled` field also requires the destination
-- application to be implemented, which conflates unrelated
-- implementation-completeness with the source flag gate this scenario is
-- about (Options has no implemented destination application in this port).
local function sourcePolicyActionById(world, id)
  local flags = FieldScriptSymbols.flagsByName
  local actions = StartMenuPolicy.actions({
    hasPokedex = world:isFlagSet(flags.FLAG_GOT_POKEDEX),
    hasStarter = world:isFlagSet(flags.FLAG_GOT_STARTER),
    bagUnlocked = world:isFlagSet(flags.FLAG_GOT_BAG),
    hasPokegear = world:isFlagSet(flags.FLAG_GOT_POKEGEAR),
    trainerCardUnlocked = world:isFlagSet(flags.FLAG_GOT_TRAINER_CARD),
    saveUnlocked = world:isFlagSet(flags.FLAG_GOT_SAVE_BUTTON),
    optionsUnlocked = world:isFlagSet(flags.FLAG_GOT_OPTIONS_BUTTON),
  })
  for _, action in ipairs(actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

function T.tests.house_mom_scene_advances_the_opening_state()
  withGame(TOWN, function(game)
    local world = game.runtime.scripts.worldState
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 0, "a genuinely fresh world starts at scene value 0")

    -- Let TOWN's own unconditional on_transition/on_resume lifecycle settle
    -- first; only script activity from here on belongs to the House 1F
    -- opening scene under test.
    game:waitForFieldEntry()
    local baselineStarts = #recordsNamed(game, "script.started")

    enterHouse(game)
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 0),
      "generated House 1F rules must have a script for scene value 0"
    )

    -- The generated on-frame lifecycle rule must start the source scene
    -- script before normal player movement can proceed; exactly one
    -- foreground script owns the field during the sequence.
    game:advanceUntil("the opening scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
    end, 30)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(#starts - baselineStarts, 1, "the opening scene must start exactly one foreground script")
    Assert.equal(
      starts[baselineStarts + 1].payload.scriptId,
      expectedSceneScriptId,
      "the generated scene-0 script must own the field"
    )
    Assert.isTrue(
      game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil,
      "the scene script must own the field"
    )

    OpeningLifecycle.completeOpeningHouseScene(game)

    for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
      Assert.isTrue(world:isFlagSet(flag), "the Mom scene must grant every early progression flag")
    end
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 1, "the Mom scene must advance the scene variable")
    Assert.isNil(game.runtime.scripts.scheduler:foregroundEnvironmentId(), "ReleaseAll must return field ownership")

    -- The root scene script also runs CallStd children (play/fade the Mom
    -- music); filter to the scene script's own end record, not its children.
    local sceneEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneEnds[#sceneEnds + 1] = record
      end
    end
    Assert.equal(#sceneEnds, 1, "the scene script must end exactly once")
    Assert.isTrue(sceneEnds[1].payload.completed, "the scene script must end by normal completion, not a fault")

    -- The predicate is no longer true (scene value is now 1, not 0), so the
    -- same frame rule must not restart on subsequent idle ticks.
    for _ = 1, 30 do
      game:step()
    end
    local sceneStartsAfterCompletion = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsAfterCompletion = sceneStartsAfterCompletion + 1
      end
    end
    Assert.equal(sceneStartsAfterCompletion, 1, "the completed opening scene must not restart")
  end, { recordingScriptHosts = true })
end

function T.tests.new_bark_friend_and_marill_scene_follows_the_house_scene()
  withGame(TOWN, function(game)
    -- Documented post-opening precondition: the House 1F Mom scene reaching
    -- this state through real script execution is covered separately above.
    -- This scenario is about New Bark's own on_transition/on_frame_eq
    -- handoff, so it seeds the same source scene value the Mom scene
    -- produces, before the very first tick (map lifecycle is still fully
    -- evaluated).
    OpeningLifecycle.seedPostOpeningHouseState(game)

    local expectedTransitionScriptId = assert(
      OpeningLifecycle.lifecycleScriptId(game.runtime, "on_transition"),
      "New Bark must declare an on_transition lifecycle script"
    )
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 1),
      "generated New Bark rules must have a script for scene value 1"
    )

    -- New Bark's on_transition lifecycle is allowed to run before ordinary
    -- frame-rule ownership.
    game:advanceUntil("New Bark's on_transition lifecycle starts", function()
      return #recordsNamed(game, "script.started") > 0
    end, 30)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(
      starts[1].payload.scriptId,
      expectedTransitionScriptId,
      "on_transition must start before the frame rule"
    )

    -- Only once that lifecycle ownership settles does the frame rule for
    -- house scene value 1 start the friend/Marill scene, exactly once.
    game:advanceUntil("the friend/Marill scene starts", function(_)
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedSceneScriptId then
          return true
        end
      end
      return false
    end, 120)
    local sceneStarts = {}
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStarts[#sceneStarts + 1] = record
      end
    end
    Assert.equal(#sceneStarts, 1, "the friend/Marill scene must start exactly once")

    local transitionEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedTransitionScriptId then
        transitionEnds[#transitionEnds + 1] = record
      end
    end
    Assert.equal(#transitionEnds, 1, "the on_transition lifecycle must end before the frame rule owns the field")

    -- Advance until its source state mutation/hide-show sequence settles:
    -- the source scene sets the house scene variable to 2 and hides both
    -- the friend and Marill.
    local world = game.runtime.scripts.worldState
    game:advanceUntil("the friend/Marill scene settles", function(snapshot)
      return world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F) == 2
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_FRIEND)
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_MARILL)
        and not snapshot.fieldLocked
    end, 400)

    local runtimeMap = game.runtime.runtimeMap
    local hiddenFlags = {
      [FLAG_HIDE_NEW_BARK_FRIEND] = true,
      [FLAG_HIDE_NEW_BARK_MARILL] = true,
    }
    local hiddenEventsChecked = 0
    for _, event in ipairs(runtimeMap.fieldData.events.objects) do
      if hiddenFlags[event.eventFlag] then
        hiddenEventsChecked = hiddenEventsChecked + 1
        local actorId = "map:" .. runtimeMap.mapId .. ":object:" .. event.objectEventId
        Assert.isNil(game.runtime.actors:getById(actorId), "a hidden New Bark actor must not remain live: " .. actorId)
        local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, event.x, event.z)
        local surface = SurfaceResolver.new(runtimeMap.terrain):resolve({
          localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
          localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
          currentY = event.y / (16 * 4096),
        })
        Assert.isNil(
          game.runtime.actors:getAt(runtimeMap.mapId, {
            fieldX = event.x,
            fieldZ = event.z,
            surfaceId = surface.surfaceId,
          }),
          "a hidden New Bark actor's source cell must have no occupant: " .. actorId
        )
      end
    end
    Assert.equal(hiddenEventsChecked, 2, "New Bark must declare both hidden friend and Marill object events")

    local reportedGhostCells = {
      { fieldX = 689, fieldZ = 394 },
      { fieldX = 689, fieldZ = 395 },
      { fieldX = 689, fieldZ = 396 },
      { fieldX = 689, fieldZ = 397 },
      { fieldX = 686, fieldZ = 403 },
      { fieldX = 687, fieldZ = 403 },
    }
    local resolver = SurfaceResolver.new(runtimeMap.terrain)
    for _, cell in ipairs(reportedGhostCells) do
      local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, cell.fieldX, cell.fieldZ)
      local candidates = runtimeMap.terrain:candidatesAt(
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
      if #candidates > 0 then
        local surface = resolver:resolve({
          localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
          localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
          currentY = 0,
        })
        Assert.isNil(
          game.runtime.actors:getAt(runtimeMap.mapId, {
            fieldX = cell.fieldX,
            fieldZ = cell.fieldZ,
            surfaceId = surface.surfaceId,
          }),
          "a reported New Bark ghost cell must have no actor occupant: " .. cell.fieldX .. ":" .. cell.fieldZ
        )
      end
    end

    -- The scene variable no longer satisfies the same one-shot trigger
    -- (value 1), so it must not restart.
    for _ = 1, 30 do
      game:step()
    end
    local sceneStartsAfter = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsAfter = sceneStartsAfter + 1
      end
    end
    Assert.equal(sceneStartsAfter, 1, "the settled friend/Marill scene must not restart")
  end, { recordingScriptHosts = true })
end

-- The friend/Marill scene's generated movement is observed through the live
-- actor and task records. All four Marill plans must retain the source waits,
-- repeated turns, jumps, walking presentation, and tile commits.
function T.tests.new_bark_marill_movement_follows_decoded_fixed_tick_choreography()
  withGame(TOWN, function(game)
    OpeningLifecycle.seedPostOpeningHouseState(game)
    local world = game.runtime.scripts.worldState
    local MARILL_ID = "map:60:object:3"

    local plans = {}
    local planOrder = {}
    local function marillTask()
      for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
        if task.status == "active" and task.taskType == "movement" and task.state.actor == MARILL_ID then
          return task
        end
      end
      return nil
    end

    local function drawRecord()
      for _, record in ipairs(game.runtime.actors:drawRecords()) do
        if record.actorId == MARILL_ID then
          return record
        end
      end
      return nil
    end

    local function withCompiledVisual(record, fn)
      local entry = assert(game.runtime.actorAssets:acquire(record.spriteId))
      local ok, result, extra = xpcall(function()
        return fn(entry.visual)
      end, debug.traceback)
      game.runtime.actorAssets:release(entry.spriteId)
      if not ok then
        error(result, 0)
      end
      return result, extra
    end

    local function isImmediate(action)
      return action.action == "set_visible"
        or action.action == "lock_facing"
        or action.action == "unlock_facing"
        or action.action == "pause_animation"
        or action.action == "resume_animation"
    end

    for step = 1, 900 do
      if game.runtime.errorText then
        error("runtime fault: " .. tostring(game.runtime.errorText))
      end
      local actor = game.runtime.actors:getById(MARILL_ID)
      local task = marillTask()
      if task and actor then
        local state = task.state
        local action = state.sequence[state.actionIndex + 1]
        if action then
          local record = assert(drawRecord(), "Marill draw record must be available while its task runs")
          local trace = plans[task.taskId]
          if trace == nil then
            trace = { records = {} }
            plans[task.taskId] = trace
            planOrder[#planOrder + 1] = task.taskId
          end
          local before = {
            action = action.action,
            direction = action.direction,
            name = action.name,
            speed = action.speed,
            distance = action.distance,
            repeatIndex = state.actionRepeat,
            activeEmoteKind = record.activeEmoteKind,
          }
          local beforeActionIndex = state.actionIndex

          if game:snapshot().dialogue.modal then
            game.runtime:pressAction()
            game:step()
            game.runtime:releaseAction()
          else
            game:step()
          end

          local afterActor = game.runtime.actors:getById(MARILL_ID)
          local afterRecord = drawRecord()
          local selectedFrameIndex = afterRecord
            and withCompiledVisual(afterRecord, function(visual)
              local frameIndex, fellBack =
                FieldActorPose.frameIndex(visual, afterRecord.facing, afterRecord.pose, afterRecord.poseTick)
              Assert.isFalse(fellBack, "Marill's real visual must provide its selected pose")
              return frameIndex
            end)
          local tracedAction = nil
          local tracedRepeat = nil
          local tracedDirection = nil
          local tracedName = nil
          local tracedSpeed = nil
          local tracedDistance = nil
          if not isImmediate(action) then
            tracedAction = before.action
            tracedRepeat = before.repeatIndex
            tracedDirection = before.direction
            tracedName = before.name
            tracedSpeed = before.speed
            tracedDistance = before.distance
          else
            local successorIndex = beforeActionIndex + 1
            local successor = state.sequence[successorIndex + 1]
            while successor ~= nil and isImmediate(successor) do
              successorIndex = successorIndex + 1
              successor = state.sequence[successorIndex + 1]
            end
            local successorState = task.state
            local successorProgressed = successor ~= nil
              and (
                successorState.actionIndex > successorIndex
                or (
                  successorState.actionIndex == successorIndex
                  and (successorState.progressTicks > 0 or successorState.actionRepeat > 0)
                )
              )
            if successorProgressed then
              tracedAction = successor.action
              tracedRepeat = successorState.actionRepeat > 0 and successorState.actionRepeat - 1 or 0
              tracedDirection = successor.direction
              tracedName = successor.name
              tracedSpeed = successor.speed
              tracedDistance = successor.distance
            end
          end
          if tracedAction ~= nil then
            trace.records[#trace.records + 1] = {
              action = tracedAction,
              direction = tracedDirection,
              name = tracedName,
              speed = tracedSpeed,
              distance = tracedDistance,
              repeatIndex = tracedRepeat,
              activeEmoteKind = before.activeEmoteKind,
              spriteId = afterRecord and afterRecord.spriteId or nil,
              facing = afterRecord and afterRecord.facing or nil,
              afterAction = afterActor and afterActor:currentAction() or nil,
              fieldX = afterActor and afterActor.fieldX or nil,
              fieldZ = afterActor and afterActor.fieldZ or nil,
              worldY = afterRecord and afterRecord.world.y or nil,
              pose = afterRecord and afterRecord.pose or nil,
              poseTick = afterRecord and afterRecord.poseTick or nil,
              frameIndex = selectedFrameIndex,
              afterEmoteKind = afterRecord and afterRecord.activeEmoteKind or nil,
            }
          end
        else
          game:step()
        end
      else
        if game:snapshot().dialogue.modal then
          game.runtime:pressAction()
          game:step()
          game.runtime:releaseAction()
        else
          game:step()
        end
      end
      if
        world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F) == 2
        and not game:snapshot().fieldLocked
        and game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil
      then
        break
      end
      if step == 900 then
        error("the friend/Marill scene did not complete")
      end
    end

    Assert.equal(#planOrder, 4, "the scene must run exactly four Marill movement plans")

    local function appendExpected(out, descriptor, repetitions)
      local ticks = MovementCalibration.actionTicks(descriptor)
      for repetition = 1, repetitions do
        for _ = 1, ticks do
          out[#out + 1] = {
            action = descriptor.action,
            direction = descriptor.direction,
            name = descriptor.name,
            speed = descriptor.speed,
            distance = descriptor.distance,
            repeatIndex = repetition - 1,
          }
        end
      end
    end

    local function assertTimeline(trace, expected, label)
      Assert.equal(
        #trace.records,
        #expected,
        label
          .. " keeps one record per calibrated action tick (expected "
          .. #expected
          .. ", got "
          .. #trace.records
          .. ")"
      )
      for index, wanted in ipairs(expected) do
        local got = trace.records[index]
        Assert.equal(got.action, wanted.action, label .. " action at tick " .. index)
        Assert.equal(got.direction, wanted.direction, label .. " direction at tick " .. index)
        Assert.equal(got.name, wanted.name, label .. " name at tick " .. index)
        Assert.equal(got.speed, wanted.speed, label .. " speed at tick " .. index)
        Assert.equal(got.distance, wanted.distance, label .. " distance at tick " .. index)
        Assert.equal(got.repeatIndex, wanted.repeatIndex, label .. " repeat index at tick " .. index)
      end
    end

    local first = plans[planOrder[1]]
    local firstExpected = {}
    appendExpected(firstExpected, { action = "delay", ticks = 32 }, 1)
    appendExpected(firstExpected, { action = "walk", direction = "north", speed = "fast", tiles = 8 }, 8)
    appendExpected(firstExpected, { action = "jump", direction = "south", distance = "near", speed = "fast" }, 1)
    appendExpected(firstExpected, { action = "face", direction = "east" }, 5)
    appendExpected(firstExpected, { action = "face", direction = "north" }, 5)
    appendExpected(firstExpected, { action = "face", direction = "west" }, 5)
    appendExpected(firstExpected, { action = "face", direction = "north" }, 5)
    appendExpected(firstExpected, { action = "walk", direction = "north", speed = "normal", tiles = 1 }, 1)
    appendExpected(firstExpected, { action = "delay", ticks = 32 }, 1)
    assertTimeline(first, firstExpected, "the arrival movement")

    local second = plans[planOrder[2]]
    local secondExpected = {}
    appendExpected(secondExpected, { action = "face", direction = "west" }, 1)
    appendExpected(secondExpected, { action = "emote", name = "exclamation" }, 1)
    appendExpected(secondExpected, { action = "walk_in_place", direction = "north", speed = "fast" }, 4)
    appendExpected(secondExpected, { action = "face", direction = "south" }, 2)
    appendExpected(secondExpected, { action = "face", direction = "east" }, 2)
    appendExpected(secondExpected, { action = "face", direction = "north" }, 2)
    appendExpected(secondExpected, { action = "face", direction = "west" }, 2)
    appendExpected(secondExpected, { action = "walk_in_place", direction = "west", speed = "fast" }, 4)
    appendExpected(secondExpected, { action = "walk", direction = "west", speed = "fast", tiles = 6 }, 6)
    assertTimeline(second, secondExpected, "the friend movement")

    local third = plans[planOrder[3]]
    local thirdExpected = {}
    appendExpected(thirdExpected, { action = "jump", direction = "west", distance = "zero", speed = "fast" }, 4)
    assertTimeline(third, thirdExpected, "the repeated zero-distance jumps")

    local jumpAnchorX, jumpAnchorZ = third.records[1].fieldX, third.records[1].fieldZ
    local jumpAnchorY = third.records[4].worldY
    for index, record in ipairs(third.records) do
      Assert.equal(record.fieldX, jumpAnchorX, "zero-distance jumps keep logical X fixed")
      Assert.equal(record.fieldZ, jumpAnchorZ, "zero-distance jumps keep logical Z fixed")
      if index % 4 == 0 then
        Assert.near(record.worldY, jumpAnchorY, 1e-9, "each zero-distance jump returns to its anchor")
        Assert.isNil(record.afterAction, "each zero-distance jump commits before its repetition")
      else
        Assert.isTrue(record.worldY > jumpAnchorY, "each zero-distance jump has an interior vertical arc")
        Assert.isTrue(
          record.worldY <= jumpAnchorY + MovementCalibration.JUMP_HEIGHTS.zero + 1e-9,
          "each zero-distance jump arc stays bounded"
        )
      end
      if index < #third.records then
        local actionTick = (index - 1) % 4
        local expectedPoseDelta = actionTick == 3 and 4 or actionTick
        local actionStart = third.records[index - actionTick]
        Assert.equal(
          record.poseTick,
          actionStart.poseTick + expectedPoseDelta,
          "fast jumps advance each sampled action at 1x"
        )
      end
    end

    local fourth = plans[planOrder[4]]
    local fourthExpected = {}
    appendExpected(fourthExpected, { action = "face", direction = "west" }, 1)
    appendExpected(fourthExpected, { action = "walk", direction = "west", speed = "normal", tiles = 1 }, 1)
    appendExpected(fourthExpected, { action = "face", direction = "south" }, 1)
    appendExpected(fourthExpected, { action = "walk", direction = "south", speed = "normal", tiles = 4 }, 4)
    appendExpected(fourthExpected, { action = "face", direction = "west" }, 1)
    appendExpected(fourthExpected, { action = "walk", direction = "west", speed = "normal", tiles = 2 }, 2)
    assertTimeline(fourth, fourthExpected, "the final normal walking movement")

    local finalAnchorX, finalAnchorZ = fourth.records[1].fieldX, fourth.records[1].fieldZ
    local completedWalks = {}
    for index, record in ipairs(fourth.records) do
      local nextRecord = fourth.records[index + 1]
      local completesSegment = nextRecord == nil
        or nextRecord.action ~= "walk"
        or nextRecord.direction ~= record.direction
      if record.action == "walk" and record.afterAction == nil and completesSegment then
        completedWalks[#completedWalks + 1] = record
      end
    end
    Assert.equal(#completedWalks, 3, "the final plan commits each normal walking segment")
    Assert.equal(completedWalks[1].fieldX, finalAnchorX - 1, "the final plan first walks west one tile")
    Assert.equal(completedWalks[1].fieldZ, finalAnchorZ, "the first west walk keeps its row")
    Assert.equal(completedWalks[2].fieldX, finalAnchorX - 1, "the final plan south walk keeps its column")
    Assert.equal(completedWalks[2].fieldZ, finalAnchorZ + 4, "the final plan walks south four tiles")
    Assert.equal(completedWalks[3].fieldX, finalAnchorX - 3, "the final plan walks west two more tiles")
    Assert.equal(completedWalks[3].fieldZ, finalAnchorZ + 4, "the final plan keeps its final row")

    -- Every source repeated-facing run remains a sequence of one-tick static
    -- facing commands. The real draw selector must therefore keep returning
    -- the idle frame while the facing and repetition order advance.
    local function assertRepeatedFaceStaysStatic(records, label)
      local index = 1
      while index <= #records do
        local record = records[index]
        if record.action ~= "face" then
          index = index + 1
        else
          local runEnd = index
          while
            records[runEnd + 1] ~= nil
            and records[runEnd + 1].action == "face"
            and records[runEnd + 1].direction == record.direction
            and records[runEnd + 1].repeatIndex == records[runEnd].repeatIndex + 1
          do
            runEnd = runEnd + 1
          end
          if runEnd > index then
            local previous = nil
            for i = index, runEnd do
              local r = records[i]
              Assert.equal(r.pose, "idle", label .. " repeated face stays idle")
              Assert.equal(r.facing, r.direction, label .. " repeated face applies each requested facing")
              Assert.notNil(r.frameIndex, label .. " repeated face must have a selected frame")
              if previous ~= nil then
                Assert.equal(r.fieldX, previous.fieldX, label .. " repeated face keeps logical fieldX fixed")
                Assert.equal(r.fieldZ, previous.fieldZ, label .. " repeated face keeps logical fieldZ fixed")
                Assert.equal(r.frameIndex, previous.frameIndex, label .. " repeated face keeps its idle frame")
              end
              previous = r
            end
          else
            Assert.equal(record.pose, "idle", label .. " single face stays idle")
          end
          index = runEnd + 1
        end
      end
    end
    assertRepeatedFaceStaysStatic(first.records, "the arrival movement")
    assertRepeatedFaceStaysStatic(second.records, "the friend movement")
    assertRepeatedFaceStaysStatic(fourth.records, "the final movement")

    local emoteSeen = false
    for _, record in ipairs(second.records) do
      if record.action == "emote" and record.afterEmoteKind == "exclamation" then
        emoteSeen = true
      end
    end
    Assert.isTrue(emoteSeen, "the exclamation remains visible during its action")

    local walkInPlaceRecords = {}
    for _, record in ipairs(second.records) do
      if record.action == "walk_in_place" then
        walkInPlaceRecords[#walkInPlaceRecords + 1] = record
        Assert.equal(record.pose, "walk", "walk-in-place uses walking presentation")
      end
    end
    Assert.equal(#walkInPlaceRecords, 32, "both walk-in-place repetitions retain their calibrated ticks")
    local firstFastRepetition = {}
    for index = 1, 4 do
      firstFastRepetition[index] = walkInPlaceRecords[index]
    end
    withCompiledVisual(firstFastRepetition[1], function(visual)
      local northWalk = assert(visual.directions.north.walk, "Marill's compiled north walk pose is required")
      local firstFrame = assert(northWalk.frames[1])
      local secondFrame = assert(northWalk.frames[2])
      local selected = {}
      for _, record in ipairs(firstFastRepetition) do
        Assert.equal(record.action, "walk_in_place", "the first fast repetition remains walk-in-place")
        Assert.equal(record.direction, "north", "the first fast repetition faces north")
        Assert.equal(record.repeatIndex, 0, "the first fast repetition has the source repetition index")
        Assert.equal(record.pose, "walk", "the first fast repetition uses walking presentation")
        local expectedFrame = assert(FieldActorPose.frameIndex(visual, record.facing, record.pose, record.poseTick))
        Assert.equal(record.frameIndex, expectedFrame, "the trace records the production-selected frame")
        selected[#selected + 1] = record.frameIndex
      end
      Assert.equal(selected[1], firstFrame.frameIndex, "the first fast tick selects the source first frame")
      Assert.isTrue(
        selected[#selected] == secondFrame.frameIndex,
        "the first fast repetition selects the source second frame before it ends"
      )
    end)
    local firstTileX, firstTileZ = walkInPlaceRecords[1].fieldX, walkInPlaceRecords[1].fieldZ
    local distinctY = {}
    for _, record in ipairs(walkInPlaceRecords) do
      Assert.equal(record.fieldX, firstTileX, "walk-in-place does not change logical X")
      Assert.equal(record.fieldZ, firstTileZ, "walk-in-place does not change logical Z")
      distinctY[record.worldY] = true
    end
    local distinctCount = 0
    for _ in pairs(distinctY) do
      distinctCount = distinctCount + 1
    end
    Assert.isTrue(distinctCount >= 2, "walk-in-place visibly bobs across fixed ticks")

    for index, record in ipairs(walkInPlaceRecords) do
      if index % 4 == 0 then
        Assert.isNil(record.afterAction, "a completed walk-in-place instance yields before its successor")
      end
    end
  end, { recordingScriptHosts = true })
end

function T.tests.new_bark_exclamation_follows_marills_current_draw_world()
  withGame(TOWN, function(game)
    OpeningLifecycle.seedPostOpeningHouseState(game)
    local marillId = "map:60:object:3"
    local renderer = FieldActorEmoteRenderer.new(game.runtime.fieldEmoteModels, emotePool())

    local function drawRecord()
      for _, record in ipairs(game.runtime.actors:drawRecords()) do
        if record.actorId == marillId then
          return record
        end
      end
      return nil
    end

    game:advanceUntil("New Bark Marill shows its exclamation", function()
      local current = drawRecord()
      return current and current.activeEmoteKind == "exclamation"
    end, 900)
    local record = assert(drawRecord())
    local activeTicks = 0
    while record.activeEmoteKind == "exclamation" do
      local items = renderer:drawItems({ record })
      Assert.equal(#items, 1, "the active Marill emote must produce one draw item")
      Assert.equal(items[1].actorId, marillId)
      Assert.near(items[1].transform[13], record.world.x, 1e-9, "the exclamation follows Marill's current world x")
      Assert.near(items[1].transform[14], record.world.y + 2, 1e-9, "the exclamation is above Marill's current world y")
      Assert.near(
        items[1].transform[15],
        record.world.z + 0.0625,
        1e-9,
        "the exclamation follows Marill's current world z"
      )
      activeTicks = activeTicks + 1
      Assert.isTrue(
        activeTicks <= MovementCalibration.EMOTE_TICKS - 1,
        "the effect must have a bounded action lifetime"
      )
      game:step()
      record = assert(drawRecord(), "Marill remains present throughout its emote action")
    end

    Assert.equal(
      activeTicks,
      MovementCalibration.EMOTE_TICKS - 1,
      "the effect lifetime remains owned by the emote action"
    )
    Assert.equal(#renderer:drawItems({ record }), 0, "clearing the emote state removes its draw item")
    renderer:dispose()
  end, { recordingScriptHosts = true })
end

function T.tests.lifecycle_predicate_survives_a_faulted_foreground_owner()
  withGame(TOWN, function(game)
    -- Same documented precondition as the New Bark scenario above: this
    -- test's purpose is lifecycle arbitration under New Bark's own
    -- on_transition + on_frame_eq handoff, not the House 1F Mom scene.
    OpeningLifecycle.seedPostOpeningHouseState(game)

    local expectedTransitionScriptId = assert(
      OpeningLifecycle.lifecycleScriptId(game.runtime, "on_transition"),
      "New Bark must declare an on_transition lifecycle script"
    )
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 1),
      "generated New Bark rules must have a script for scene value 1"
    )

    -- The on_frame_eq predicate for house scene value 1 is already true the
    -- entire time: it must not start concurrently with the on_transition
    -- lifecycle, and it must not be treated as lost once ownership frees up.
    -- New Bark's real on_transition script has no unsupported branch left to
    -- reach on a fresh world (every opcode it exercises is implemented and
    -- none of them block), so it now runs to completion within the single
    -- tick it starts on, leaving no window to observe it mid-flight. This
    -- scenario widens that window with the scheduler's own per-tick node
    -- budget (a real diagnostic control, `Scheduler:setMaxNodes`, documented
    -- for tests), then ends the still-running instance deterministically at
    -- the scheduler's error boundary: a real production `cancelInstance`
    -- call, the same termination path a faulted task escalates through,
    -- produces the identical `script.ended` (completed=false, reason set)
    -- surface this contract requires.
    game.runtime.scripts.scheduler:setMaxNodes(1)
    local transitionInstanceId
    game:advanceUntil("New Bark's on_transition lifecycle starts", function()
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedTransitionScriptId then
          transitionInstanceId = record.payload.instanceId
          return true
        end
      end
      return false
    end, 30)
    game.runtime.scripts.scheduler:cancelInstance(assert(transitionInstanceId), "acceptance-injected termination")

    game:advanceUntil("New Bark's on_transition lifecycle ends", function()
      for _, record in ipairs(recordsNamed(game, "script.ended")) do
        if record.payload.scriptId == expectedTransitionScriptId then
          return true
        end
      end
      return false
    end, 30)

    local transitionEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedTransitionScriptId then
        transitionEnds[#transitionEnds + 1] = record
      end
    end
    Assert.equal(#transitionEnds, 1, "the on_transition lifecycle must surface exactly one end record")
    Assert.isFalse(
      transitionEnds[1].payload.completed,
      "the faulted lifecycle must not be reported as successful completion"
    )
    Assert.notNil(transitionEnds[1].payload.reason, "the fault identity must be observable")

    local sceneStartsWhileTransitionOwnedField = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsWhileTransitionOwnedField = sceneStartsWhileTransitionOwnedField + 1
      end
    end
    Assert.equal(
      sceneStartsWhileTransitionOwnedField,
      0,
      "the frame rule must not start while the on_transition lifecycle still owns the field"
    )

    -- The frame predicate remained true throughout and must become eligible
    -- again now that ownership is free; it was not permanently lost because
    -- it was observed while blocked.
    game:advanceUntil("the frame rule starts after the faulted lifecycle releases ownership", function()
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedSceneScriptId then
          return true
        end
      end
      return false
    end, 60)
    local sceneStarts = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStarts = sceneStarts + 1
      end
    end
    Assert.equal(sceneStarts, 1, "the frame rule must start exactly once after ownership frees up")
  end, { recordingScriptHosts = true })
end

function T.tests.mom_source_flags_gate_early_start_menu_state()
  withGame(TOWN, function(game)
    local world = game.runtime.scripts.worldState

    -- Before Mom grants the flags: Bag stays inhibited entirely (absent
    -- from the menu), Trainer Card/Save stay present but disabled (through
    -- the fully composed application host), and Options stays source-locked
    -- (through the pure source policy directly, since Options has no
    -- implemented destination application in this port).
    local before = openMenu(game)
    Assert.isNil(actionById(before, "vanilla.bag"), "Bag must stay inhibited before Mom grants it")
    Assert.isFalse(actionById(before, "vanilla.trainer_card").enabled, "Trainer Card must stay locked before Mom")
    Assert.isFalse(actionById(before, "vanilla.save").enabled, "Save must stay locked before Mom")
    Assert.isFalse(
      sourcePolicyActionById(world, "vanilla.options").sourceEnabled,
      "Options must stay source-locked before Mom"
    )
    closeMenu(game)

    enterHouse(game)
    OpeningLifecycle.completeOpeningHouseScene(game)

    -- After Mom grants the flags: the same live world flags now
    -- enable/present the implemented actions, through the existing
    -- production Start Menu policy composition alone.
    local after = openMenu(game)
    Assert.notNil(actionById(after, "vanilla.bag"), "Bag must become present once Mom grants it")
    Assert.isTrue(actionById(after, "vanilla.trainer_card").enabled, "Trainer Card must unlock after Mom")
    Assert.isTrue(actionById(after, "vanilla.save").enabled, "Save must unlock after Mom")
    Assert.isTrue(
      sourcePolicyActionById(world, "vanilla.options").sourceEnabled,
      "Options must unlock at the source policy after Mom"
    )
    closeMenu(game)
  end, { recordingScriptHosts = true })
end

return T
