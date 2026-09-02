-- Scripted-actor presentation lifecycle: proves facing/pose transitions on
-- the real FieldObjectActor driven through the production
-- Scheduler/MovementTask/ScriptActorWorld/FieldActorManager wiring (not the
-- script-facing FakeActors fake), since the reported stale-walk-pose defect
-- only reproduces through that composition.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Schema = require("libs.script.src.Schema")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local MovementTask = require("libs.hgss.src.script.tasks.MovementTask")
---@cast MovementTask TaskImplementation
local MovementBarrierTask = require("libs.hgss.src.script.tasks.MovementBarrierTask")
---@cast MovementBarrierTask TaskImplementation
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local FakeServices = require("tests.support.script.FakeServices")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local FieldActorManager = require("libs.hgss.src.field.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.field.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")

local T = {}

local POLICY = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } }
local ACTOR_ID = "map:61:object:0"

local function terrain()
  return TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
end

local function runtimeMap()
  local result = {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    fieldData = {
      events = {
        objects = {
          {
            index = 0,
            objectEventId = 0,
            spriteId = 99,
            movementType = "stationary",
            type = 0,
            eventFlag = 500,
            scriptId = 1,
            facingDirection = "south",
            facingDirectionRaw = 1,
            param0 = 0,
            param1 = 0,
            param2 = 0,
            xRange = 0,
            yRange = 0,
            x = 2,
            z = 3,
            y = 0,
          },
        },
        background = {},
        warps = {},
        coordinates = {},
      },
    },
  }
  ---@cast result RuntimeFieldMap
  return result
end

local function fakeAssets(opts)
  opts = opts or {}
  local visual = opts.visual or FieldActorFixture.visual(99, { frameCount = 8 })
  return {
    knows = function()
      return true
    end,
    acquire = function(_, id)
      return { spriteId = id, visual = visual }
    end,
    release = function() end,
  }
end

-- Wires the real production actor stack (FieldActorManager -> ScriptActorWorld)
-- behind the same Scheduler/MovementTask machinery movement_test.lua exercises
-- against FakeActors, so presentation state (facing/pose) is observed on the
-- concrete FieldObjectActor a production renderer would read.
local function harness(opts)
  local mgr = FieldActorManager.new({ assets = fakeAssets(opts), policy = POLICY })
  local eventState = FieldEventState.new()
  mgr:enterMap(runtimeMap(), eventState)
  local player = {
    position = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
    gender = function()
      return 0
    end,
    name = function()
      return "Gold"
    end,
  }
  local world = ScriptActorWorld.new(mgr --[[@as ScriptActorManager]], player)
  local services = FakeServices.new()
  services.audio = {
    play = function() end,
  }
  services.world = eventState
  services.actors = world
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("movement", 1, MovementTask)
  taskRegistry:register("movement_barrier", 1, MovementBarrierTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return { mgr = mgr, registry = registry, composition = composition, scheduler = scheduler }
end

local function startForeground(h, resource, tick)
  h.registry:installBase(resource.id, resource, "generated")
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, nil, tick)
end

local function staticVisual()
  return FieldActorFixture.visual(99, { frameCount = 8 })
end

local function followerVisual()
  local frameOffsets = {}
  for frameIndex = 1, 8 do
    frameOffsets[frameIndex] = 0
  end
  frameOffsets[5] = -0.5
  local visual = FieldActorFixture.visual(99, {
    frameCount = 8,
    idlePresentation = {
      mode = "animated",
      cadence = 1,
      frameOffsets = frameOffsets,
    },
  })
  for _, direction in ipairs({ "north", "south", "west", "east" }) do
    visual.directions[direction].idle = visual.directions[direction].walk
  end
  return visual
end

-- Keep the component scenario in the same order as FieldSession: the script
-- scheduler owns the first half of a world tick and the actor manager owns the
-- second half. The autonomous lock keeps this stationary fixture focused on
-- scripted presentation rather than its unrelated controller policy.
local function stepWorld(h, tick)
  h.scheduler:step(tick, nil)
  h.mgr:step(tick, { autonomousLocked = true })
end

function T.ordinary_actor_settles_to_static_idle_after_locomotion()
  local h = harness({ visual = staticVisual() })
  local resource = S.script({
    api = 1,
    id = "test.static_idle_after_walk",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.walk({ direction = "east", speed = "normal", tiles = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  stepWorld(h, 100)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  for tick = 101, 120 do
    stepWorld(h, tick)
    if h.scheduler:foregroundEnvironmentId() == nil then
      break
    end
  end

  Assert.isNil(actor:currentAction(), "the locomotion action must be exhausted")
  local settledPoseTick = actor.poseTick
  local fieldX, fieldZ = actor.fieldX, actor.fieldZ
  local worldX, worldY, worldZ = actor.worldX, actor.worldY, actor.worldZ
  for tick = 121, 123 do
    stepWorld(h, tick)
    Assert.isNil(actor:currentAction(), "taskless ticks must not recreate a movement action")
    Assert.equal(actor.pose, "idle", "ordinary actor settles to its visual idle pose")
    Assert.equal(actor.poseTick, settledPoseTick, "static idle does not advance its pose phase")
    Assert.equal(actor.fieldX, fieldX, "static idle keeps logical fieldX")
    Assert.equal(actor.fieldZ, fieldZ, "static idle keeps logical fieldZ")
    Assert.equal(actor.worldX, worldX, "static idle keeps logical worldX")
    Assert.equal(actor.worldY, worldY, "static idle keeps logical worldY")
    Assert.equal(actor.worldZ, worldZ, "static idle keeps logical worldZ")
    local record = assert(h.mgr:drawRecords()[1])
    Assert.equal(record.world.x, worldX, "static idle keeps draw worldX at its logical anchor")
    Assert.equal(record.world.y, worldY, "static idle keeps draw worldY at its logical anchor")
    Assert.equal(record.world.z, worldZ, "static idle keeps draw worldZ at its logical anchor")
  end
end

function T.follower_actor_animates_from_idle_before_and_after_locomotion()
  local h = harness({ visual = followerVisual() })
  local resource = S.script({
    api = 1,
    id = "test.animated_idle_lifecycle",
    steps = {
      S.waitTicks({ ticks = 2 }),
      S.applyMovement({
        actor = ACTOR_ID,
        movement = { S.m.walk({ direction = "east", speed = "normal", tiles = 1 }) },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  stepWorld(h, 100)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  local initialPoseTick = actor.poseTick

  stepWorld(h, 101)
  Assert.equal(actor.pose, "idle", "a follower begins with its visual idle pose")
  Assert.equal(actor.poseTick, initialPoseTick + 1, "follower idle advances at source 1x cadence")
  stepWorld(h, 102)
  Assert.equal(actor.pose, "idle", "follower remains in its visual idle pose")
  Assert.equal(actor.poseTick, initialPoseTick + 2, "follower idle continues at source 1x cadence")

  for tick = 103, 120 do
    stepWorld(h, tick)
    if h.scheduler:foregroundEnvironmentId() == nil then
      break
    end
  end
  Assert.isNil(actor:currentAction(), "the follower locomotion action must be exhausted")
  local settledPoseTick = actor.poseTick
  stepWorld(h, 121)
  Assert.equal(actor.pose, "idle", "follower returns to visual idle after locomotion")
  Assert.equal(actor.poseTick, settledPoseTick + 1, "follower idle does not depend on the prior action descriptor")
  stepWorld(h, 122)
  Assert.equal(actor.poseTick, settledPoseTick + 2, "follower idle keeps advancing without an active action")
end

function T.paused_follower_idle_freezes_phase_and_display_offset()
  local h = harness({ visual = followerVisual() })
  local actor = assert(h.mgr:getById(ACTOR_ID))
  stepWorld(h, 100)
  stepWorld(h, 101)
  stepWorld(h, 102)
  local pausedPoseTick = actor.poseTick
  local pausedOffset = actor.presentationOffset.y
  local worldX, worldY, worldZ = actor.worldX, actor.worldY, actor.worldZ

  h.mgr:setAnimationPaused(ACTOR_ID, true)
  stepWorld(h, 103)
  Assert.equal(actor.pose, "idle", "paused follower remains in its visual idle pose")
  Assert.equal(actor.poseTick, pausedPoseTick, "paused follower idle holds its pose phase")
  Assert.equal(actor.presentationOffset.y, pausedOffset, "paused follower idle holds its display offset")
  Assert.equal(actor.worldX, worldX, "paused follower idle keeps logical worldX")
  Assert.equal(actor.worldY, worldY, "paused follower idle keeps logical worldY")
  Assert.equal(actor.worldZ, worldZ, "paused follower idle keeps logical worldZ")

  h.mgr:setAnimationPaused(ACTOR_ID, false)
  stepWorld(h, 104)
  Assert.equal(actor.poseTick, pausedPoseTick + 1, "resumed follower idle advances by one source tick")
  Assert.equal(actor.worldX, worldX, "resumed follower idle keeps logical worldX")
  Assert.equal(actor.worldY, worldY, "resumed follower idle keeps logical worldY")
  Assert.equal(actor.worldZ, worldZ, "resumed follower idle keeps logical worldZ")
end

function T.follower_idle_presentation_advances_during_delay_without_double_advancing()
  local h = harness({ visual = followerVisual() })
  local actor = assert(h.mgr:getById(ACTOR_ID))
  h.mgr:beginScriptedAction(ACTOR_ID, { action = "delay" })
  local initialPoseTick = actor.poseTick

  h.mgr:advanceScriptedAction(ACTOR_ID, 1, 32)
  Assert.equal(actor.pose, "idle", "a delay uses the follower's idle pose")
  Assert.equal(actor.poseTick, initialPoseTick + 1, "a delay advances follower idle by one source tick")
  h.mgr:step(100, { autonomousLocked = true })
  Assert.equal(actor.poseTick, initialPoseTick + 1, "the manager does not double-advance a scripted delay tick")

  h.mgr:advanceScriptedAction(ACTOR_ID, 2, 32)
  h.mgr:advanceScriptedAction(ACTOR_ID, 3, 32)
  Assert.equal(actor.poseTick, initialPoseTick + 3, "successive delay ticks advance follower idle exactly once")
  Assert.equal(actor.presentationOffset.y, -0.5, "delay idle applies the displayed frame's bob")
  h.mgr:step(101, { autonomousLocked = true })
  Assert.equal(actor.poseTick, initialPoseTick + 3, "the manager does not add a second delay tick")
  Assert.equal(actor.presentationOffset.y, -0.5, "the scripted delay bob remains stable for the published tick")

  h.mgr:commitScriptedAction(ACTOR_ID)
  Assert.isNil(actor:currentAction(), "the delay commits normally")
  Assert.equal(actor.pose, "idle", "a committed delay remains in follower idle")

  h.mgr:beginScriptedAction(ACTOR_ID, { action = "emote", name = "exclamation" })
  local emotePoseTick = actor.poseTick
  h.mgr:advanceScriptedAction(ACTOR_ID, 1, 32)
  Assert.equal(actor.pose, "idle", "an emote uses the follower's idle pose")
  Assert.equal(actor.poseTick, emotePoseTick + 1, "an emote advances follower idle by one source tick")
  h.mgr:step(102, { autonomousLocked = true })
  Assert.equal(actor.poseTick, emotePoseTick + 1, "the manager does not double-advance a scripted emote tick")
end

function T.locked_face_returns_to_visual_idle_presentation()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.locked_face_visual_idle",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.walk({ direction = "east", speed = "fast", tiles = 1 }),
          S.m.lockFacing(),
          S.m.face({ direction = "west" }),
          S.m.delay({ ticks = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  stepWorld(h, 100)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  for tick = 101, 104 do
    stepWorld(h, tick)
  end
  Assert.equal(actor.facing, "east", "the locomotion establishes the actor facing")
  Assert.equal(actor.pose, "idle", "the completed locomotion uses visual idle presentation")
  local poseTickBeforeFace = actor.poseTick
  stepWorld(h, 105)
  Assert.equal(actor.facing, "east", "a face suppressed by the facing lock keeps the current facing")
  Assert.equal(actor.pose, "idle", "a face suppressed by the facing lock keeps visual idle presentation")
  Assert.equal(actor.poseTick, poseTickBeforeFace, "a suppressed face does not advance static idle")

  stepWorld(h, 106)
  Assert.equal(actor.pose, "idle", "the following delay keeps visual idle presentation")
  Assert.equal(actor.poseTick, poseTickBeforeFace, "the following delay does not inherit locomotion cadence")
end

-- `walk -> walk -> walk_in_place (two repetitions) -> delay` (all "fast", 4
-- ticks per action) must present one continuous locomotion pose across every
-- timed boundary. Each completed action settles to the visual idle profile and
-- leaves no previous-action presentation state behind.
function T.contiguous_locomotion_returns_to_visual_idle_between_actions()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.chain",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.walk({ direction = "east", speed = "fast", tiles = 1 }),
          S.m.walk({ direction = "east", speed = "fast", tiles = 1 }),
          S.m.walkInPlace({ direction = "east", speed = "fast", count = 2 }),
          S.m.delay({ ticks = 2 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  for tick = 101, 108 do
    h.scheduler:step(tick, nil)
    local expectedPose = "walk"
    if tick == 104 or tick == 108 then
      expectedPose = "idle"
    end
    Assert.equal(actor.pose, expectedPose, "the locomotion chain publishes its action boundary at tick " .. tick)
  end
  local fieldX, fieldZ = actor.fieldX, actor.fieldZ
  local worldX, worldY, worldZ = actor.worldX, actor.worldY, actor.worldZ
  local poseTickBeforeWalkInPlace = actor.poseTick
  local sawBob = false
  for tick = 109, 111 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor:currentAction(), "walk_in_place", "the first walk-in-place instance is active")
    Assert.equal(actor.pose, "walk", "walk-in-place uses walking presentation")
    Assert.equal(
      actor.poseTick,
      poseTickBeforeWalkInPlace + 2 * (tick - 108),
      "the first fast walk-in-place continues the accumulated pose phase"
    )
    Assert.equal(actor.fieldX, fieldX, "walk-in-place keeps logical X fixed")
    Assert.equal(actor.fieldZ, fieldZ, "walk-in-place keeps logical Z fixed")
    Assert.equal(actor.worldX, worldX, "walk-in-place keeps world X at its anchor")
    Assert.equal(actor.worldY, worldY, "walk-in-place keeps world Y at its anchor")
    Assert.equal(actor.worldZ, worldZ, "walk-in-place keeps world Z at its anchor")
    sawBob = sawBob or actor.presentationOffset.y ~= 0
  end
  Assert.isTrue(sawBob, "walk-in-place visibly bobs during its action")
  -- The first walk-in-place repetition commits at 112's boundary. Its
  -- transaction clears the bob, and the second repetition begins on the next
  -- poll with a fresh presentation offset.
  h.scheduler:step(112, nil)
  Assert.isNil(actor:currentAction(), "a completed walk-in-place yields before its repetition")
  Assert.equal(actor.pose, "idle", "a completed walk-in-place returns to visual idle")
  Assert.equal(actor.presentationOffset.y, 0, "a committed walk-in-place clears its bob")
  Assert.equal(
    actor.poseTick,
    poseTickBeforeWalkInPlace + 8,
    "the first fast repetition advances exactly four ticks at 2x"
  )
  Assert.equal(actor.worldX, worldX, "a completed walk-in-place keeps world X at its anchor")
  Assert.equal(actor.worldY, worldY, "a completed walk-in-place keeps world Y at its anchor")
  Assert.equal(actor.worldZ, worldZ, "a completed walk-in-place keeps world Z at its anchor")
  h.scheduler:step(113, nil)
  Assert.equal(actor:currentAction(), "walk_in_place", "the second walk-in-place instance starts next poll")
  Assert.isTrue(actor.presentationOffset.y ~= 0, "the second instance gets a fresh bob")
  Assert.equal(
    actor.poseTick,
    poseTickBeforeWalkInPlace + 10,
    "the second fast repetition continues without a phase reset"
  )
  Assert.equal(actor.fieldX, fieldX, "the second walk-in-place keeps logical X fixed")
  Assert.equal(actor.fieldZ, fieldZ, "the second walk-in-place keeps logical Z fixed")
  Assert.equal(actor.worldX, worldX, "the second walk-in-place keeps world X at its anchor")
  Assert.equal(actor.worldY, worldY, "the second walk-in-place keeps world Y at its anchor")
  Assert.equal(actor.worldZ, worldZ, "the second walk-in-place keeps world Z at its anchor")
  for tick = 114, 115 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor.pose, "walk", "the second walk-in-place remains walking")
    Assert.equal(
      actor.poseTick,
      poseTickBeforeWalkInPlace + 2 * (tick - 108),
      "the second fast walk-in-place keeps the accumulated pose phase"
    )
    Assert.equal(actor.fieldX, fieldX, "the second walk-in-place keeps logical X fixed")
    Assert.equal(actor.fieldZ, fieldZ, "the second walk-in-place keeps logical Z fixed")
    Assert.equal(actor.worldX, worldX, "the second walk-in-place keeps world X at its anchor")
    Assert.equal(actor.worldY, worldY, "the second walk-in-place keeps world Y at its anchor")
    Assert.equal(actor.worldZ, worldZ, "the second walk-in-place keeps world Z at its anchor")
  end
  h.scheduler:step(116, nil)
  Assert.isNil(actor:currentAction(), "the second walk-in-place commits independently")
  Assert.equal(actor.pose, "idle", "the second completed walk-in-place returns to visual idle")
  Assert.equal(actor.presentationOffset.y, 0, "the second commit clears its bob")
  Assert.equal(
    actor.poseTick,
    poseTickBeforeWalkInPlace + 16,
    "two fast repetitions retain their full calibrated bob duration"
  )
  Assert.equal(actor.worldX, worldX, "the second completed walk-in-place keeps world X at its anchor")
  Assert.equal(actor.worldY, worldY, "the second completed walk-in-place keeps world Y at its anchor")
  Assert.equal(actor.worldZ, worldZ, "the second completed walk-in-place keeps world Z at its anchor")
  -- The trailing delay begins on the following poll without inheriting the
  -- final locomotion cadence while its actor remains at the anchor.
  h.scheduler:step(117, nil)
  Assert.equal(actor.pose, "idle", "the trailing delay uses visual idle presentation")
  Assert.equal(actor.poseTick, poseTickBeforeWalkInPlace + 16, "the trailing delay does not advance static idle")
  h.scheduler:step(118, nil)
  Assert.equal(actor.pose, "idle", "task completion keeps visual idle presentation")
  Assert.equal(actor.poseTick, poseTickBeforeWalkInPlace + 16, "task completion keeps static idle phase")
end

-- `face east, count=5` followed by a trailing delay (so the fifth
-- repetition's boundary tick is independently observable) must remain a
-- static facing action while world/field coordinates stay at the exact
-- anchor for every one of its five one-tick repetitions.
function T.repeated_face_action_stays_static_at_fixed_coordinates()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.repeated_face",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.face({ direction = "east", count = 5 }),
          S.m.delay({ ticks = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  local fieldX, fieldZ = actor.fieldX, actor.fieldZ
  local worldX, worldY, worldZ = actor.worldX, actor.worldY, actor.worldZ

  for tick = 101, 105 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor.pose, "idle", "a repeated face must remain idle on tick " .. tick)
    Assert.equal(actor.poseTick, 0, "a repeated face must hold the idle pose phase on tick " .. tick)
    Assert.equal(actor.fieldX, fieldX, "a repeated face must never move logical fieldX (tick " .. tick .. ")")
    Assert.equal(actor.fieldZ, fieldZ, "a repeated face must never move logical fieldZ (tick " .. tick .. ")")
    Assert.equal(actor.worldX, worldX, "a repeated face must never move worldX (tick " .. tick .. ")")
    Assert.equal(actor.worldY, worldY, "a repeated face must never move worldY (tick " .. tick .. ")")
    Assert.equal(actor.worldZ, worldZ, "a repeated face must never move worldZ (tick " .. tick .. ")")
    Assert.equal(actor.presentationOffset.y, 0, "a repeated face gets no bob presentation offset")
  end
  Assert.equal(actor.facing, "east", "the fifth repetition still applies the source final facing")

  h.scheduler:step(106, nil)
  Assert.equal(actor.pose, "idle", "the trailing delay keeps the repeated face idle")
end

-- A single face (`count` defaults to `1`) is an idle-facing action, not a
-- stationary animated one: it must never enter walking presentation or
-- advance the pose clock, even though it shares `beginScriptedAction` with
-- the repeated case above.
function T.single_face_action_stays_idle_and_does_not_advance_pose()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.single_face",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.face({ direction = "south" }),
          S.m.delay({ ticks = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  local startingPoseTick = actor.poseTick

  h.scheduler:step(101, nil)
  Assert.equal(actor.pose, "idle", "a single face must not enter walking presentation")
  Assert.equal(actor.poseTick, startingPoseTick, "a single face must not advance the pose clock")
  Assert.equal(actor.facing, "south", "a single face still applies its facing")

  h.scheduler:step(102, nil)
  Assert.equal(actor.pose, "idle", "the trailing delay remains idle after a single face")
end

-- A single face, a repeated face, and an explicit `walk_in_place` run back to
-- back on one actor: facing repetitions stay static while walk-in-place keeps
-- its own active presentation and timing.
function T.face_repetitions_and_walk_in_place_preserve_action_boundaries()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.three_way_distinction",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.face({ direction = "east" }),
          S.m.face({ direction = "south", count = 3 }),
          S.m.walkInPlace({ direction = "south", speed = "fast", count = 1 }),
          S.m.delay({ ticks = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  local fieldX, fieldZ = actor.fieldX, actor.fieldZ

  -- Tick 101: the single face (count defaults to 1) completes in one poll.
  h.scheduler:step(101, nil)
  Assert.equal(actor.pose, "idle", "a single face never enters walking presentation")
  Assert.equal(actor.presentationOffset.y, 0, "a single face has no bob")
  Assert.equal(actor.facing, "east", "the single face applies its own facing")

  -- Ticks 102-104: the repeated face (three one-tick repetitions) stays
  -- static without bob while logical coordinates hold.
  for tick = 102, 104 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor.pose, "idle", "a repeated face stays idle (tick " .. tick .. ")")
    Assert.equal(actor.poseTick, 0, "a repeated face holds the idle pose phase (tick " .. tick .. ")")
    Assert.equal(actor.presentationOffset.y, 0, "a repeated face never bobs (tick " .. tick .. ")")
    Assert.equal(actor.fieldX, fieldX, "a repeated face keeps logical fieldX fixed (tick " .. tick .. ")")
    Assert.equal(actor.fieldZ, fieldZ, "a repeated face keeps logical fieldZ fixed (tick " .. tick .. ")")
  end
  Assert.equal(actor.facing, "south", "the repeated face's final repetition applies its facing")

  -- Ticks 105-107: explicit walk_in_place (fast = 4 ticks) walks and bobs,
  -- keeping its own established, distinct presentation.
  local sawBob = false
  for tick = 105, 107 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor:currentAction(), "walk_in_place", "walk_in_place is active (tick " .. tick .. ")")
    Assert.equal(actor.pose, "walk", "walk_in_place presents walking pose (tick " .. tick .. ")")
    Assert.equal(actor.fieldX, fieldX, "walk_in_place keeps logical fieldX fixed (tick " .. tick .. ")")
    Assert.equal(actor.fieldZ, fieldZ, "walk_in_place keeps logical fieldZ fixed (tick " .. tick .. ")")
    sawBob = sawBob or actor.presentationOffset.y ~= 0
  end
  Assert.isTrue(sawBob, "explicit walk_in_place keeps its own deterministic bob")

  -- Tick 108: walk_in_place's fourth and final tick completes and commits in
  -- the same poll (mirroring the pre-existing walk/walk_in_place boundary
  -- pattern elsewhere in this file); the completed action remains the
  -- observable idle presentation for this boundary tick.
  h.scheduler:step(108, nil)
  Assert.isNil(actor:currentAction(), "walk_in_place has committed by its boundary tick")
  Assert.equal(actor.pose, "idle", "the completed walk_in_place settles on its boundary tick")
  Assert.equal(actor.fieldX, fieldX, "walk_in_place's boundary tick keeps logical fieldX fixed")
  Assert.equal(actor.fieldZ, fieldZ, "walk_in_place's boundary tick keeps logical fieldZ fixed")

  -- Tick 109: the trailing delay does not inherit the completed walk-in-place's
  -- cadence while the actor stays at its anchor.
  h.scheduler:step(109, nil)
  Assert.equal(actor.pose, "idle", "the sequence uses visual idle once the delay begins")
  Assert.equal(actor.poseTick, 8, "the trailing delay does not advance static idle")
  Assert.equal(actor.presentationOffset.y, 0, "settling clears any residual bob")
end

local function cadenceVisual()
  local visual = FieldActorFixture.visual(99, { frameCount = 8 })
  visual.directions.east.walk = {
    frames = {
      { frameIndex = 4, ticks = 5 },
      { frameIndex = 5, ticks = 10 },
      { frameIndex = 6, ticks = 5 },
    },
    loop = true,
    durationTicks = 20,
  }
  return visual
end

local function runLocomotion(action)
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.source_rate_" .. action.action .. "_" .. (action.speed or action.distance),
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          action,
          S.m.delay({ ticks = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  local visual = cadenceVisual()
  local durationTicks = MovementCalibration.actionTicks(action)
  local startFieldX, startFieldZ = actor.fieldX, actor.fieldZ
  local startWorldY = actor.worldY
  local poseTicks, frameIndexes = {}, {}
  ---@type number[]
  local worldYs = {}
  for progress = 1, durationTicks do
    h.scheduler:step(100 + progress, nil)
    local expectedPose = progress < durationTicks and "walk" or "idle"
    Assert.equal(actor.pose, expectedPose, "locomotion settles to visual idle on its final tick")
    if progress < durationTicks then
      Assert.equal(actor:currentAction(), action.action, "the action duration remains source-calibrated")
    else
      Assert.isNil(actor:currentAction(), "the action commits on its existing final tick")
    end
    poseTicks[#poseTicks + 1] = actor.poseTick
    frameIndexes[#frameIndexes + 1] =
      assert(FieldActorPose.frameIndex(visual, actor.facing, actor.pose, actor.poseTick))
    worldYs[#worldYs + 1] = assert(actor.worldY)
  end
  return {
    actor = actor,
    startFieldX = startFieldX,
    startFieldZ = startFieldZ,
    startWorldY = startWorldY,
    poseTicks = poseTicks,
    frameIndexes = frameIndexes,
    worldYs = worldYs,
    durationTicks = durationTicks,
  }
end

function T.source_backed_locomotion_matrix_preserves_timing_and_visible_frames()
  local cases = {
    {
      label = "walk slow",
      action = { action = "walk", direction = "east", speed = "slow", tiles = 1 },
      poseTicks = { 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8 },
      frameIndexes = { 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5 },
      endFieldX = 3,
      endFieldZ = 3,
    },
    {
      label = "walk normal",
      action = { action = "walk", direction = "east", speed = "normal", tiles = 1 },
      poseTicks = { 1, 2, 3, 4, 5, 6, 7, 8 },
      frameIndexes = { 4, 4, 4, 4, 5, 5, 5, 5 },
      endFieldX = 3,
      endFieldZ = 3,
    },
    {
      label = "walk fast",
      action = { action = "walk", direction = "east", speed = "fast", tiles = 1 },
      poseTicks = { 2, 4, 6, 8 },
      frameIndexes = { 4, 4, 5, 5 },
      endFieldX = 3,
      endFieldZ = 3,
    },
    {
      label = "walk slightly fast",
      action = { action = "walk", direction = "east", speed = "slightly_fast", tiles = 1 },
      poseTicks = { 1, 2, 4, 5, 6, 8 },
      frameIndexes = { 4, 4, 4, 5, 5, 5 },
      endFieldX = 3,
      endFieldZ = 3,
    },
    {
      label = "walk run",
      action = { action = "walk", direction = "east", speed = "run", tiles = 1 },
      poseTicks = { 2, 4 },
      frameIndexes = { 4, 4 },
      endFieldX = 3,
      endFieldZ = 3,
    },
    {
      label = "walk-in-place slower",
      action = { action = "walk_in_place", direction = "east", speed = "slower" },
      poseTicks = { 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12 },
      frameIndexes = { 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 },
      endFieldX = 2,
      endFieldZ = 3,
    },
    {
      label = "walk-in-place slow",
      action = { action = "walk_in_place", direction = "east", speed = "slow" },
      poseTicks = { 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8 },
      frameIndexes = { 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5 },
      endFieldX = 2,
      endFieldZ = 3,
    },
    {
      label = "walk-in-place normal",
      action = { action = "walk_in_place", direction = "east", speed = "normal" },
      poseTicks = { 1, 2, 3, 4, 5, 6, 7, 8 },
      frameIndexes = { 4, 4, 4, 4, 5, 5, 5, 5 },
      endFieldX = 2,
      endFieldZ = 3,
    },
    {
      label = "walk-in-place fast",
      action = { action = "walk_in_place", direction = "east", speed = "fast" },
      poseTicks = { 2, 4, 6, 8 },
      frameIndexes = { 4, 4, 5, 5 },
      endFieldX = 2,
      endFieldZ = 3,
    },
    {
      label = "zero jump slow",
      action = { action = "jump", direction = "east", distance = "zero", speed = "slow" },
      poseTicks = { 0, 1, 1, 2 },
      frameIndexes = { 4, 4, 4, 4 },
      endFieldX = 2,
      endFieldZ = 3,
    },
    {
      label = "zero jump fast",
      action = { action = "jump", direction = "east", distance = "zero", speed = "fast" },
      poseTicks = { 1, 2, 3, 4 },
      frameIndexes = { 4, 4, 4, 4 },
      endFieldX = 2,
      endFieldZ = 3,
    },
    {
      label = "near jump fast",
      action = { action = "jump", direction = "east", distance = "near", speed = "fast" },
      poseTicks = { 1, 2, 3, 4, 5, 6 },
      frameIndexes = { 4, 4, 4, 4, 5, 5 },
      endFieldX = 3,
      endFieldZ = 3,
    },
    {
      label = "far jump fast",
      action = { action = "jump", direction = "east", distance = "far", speed = "fast" },
      poseTicks = { 1, 2, 3, 4, 5, 6, 7, 8 },
      frameIndexes = { 4, 4, 4, 4, 5, 5, 5, 5 },
      endFieldX = 3,
      endFieldZ = 3,
    },
  }

  for _, case in ipairs(cases) do
    local observed = runLocomotion(case.action)
    Assert.equal(
      observed.durationTicks,
      MovementCalibration.actionTicks(case.action),
      case.label .. " retains duration"
    )
    Assert.deepEqual(observed.poseTicks, case.poseTicks, case.label .. " uses the source pose cadence")
    local expectedFrames = {}
    for index, frameIndex in ipairs(case.frameIndexes) do
      expectedFrames[index] = frameIndex
    end
    expectedFrames[#expectedFrames] =
      FieldActorPose.frameIndex(cadenceVisual(), "east", "idle", case.poseTicks[#case.poseTicks])
    Assert.deepEqual(observed.frameIndexes, expectedFrames, case.label .. " selects the source frame timeline")
    Assert.equal(observed.actor.fieldX, case.endFieldX, case.label .. " retains its physical X result")
    Assert.equal(observed.actor.fieldZ, case.endFieldZ, case.label .. " retains its physical Z result")
    if case.action.action == "walk_in_place" then
      Assert.equal(observed.actor.fieldX, observed.startFieldX, case.label .. " does not translate")
      Assert.equal(observed.actor.fieldZ, observed.startFieldZ, case.label .. " does not translate")
      Assert.equal(observed.actor.presentationOffset.y, 0, case.label .. " clears its bob at completion")
    end
    if case.action.action == "jump" then
      local startWorldY = assert(observed.startWorldY)
      Assert.equal(observed.actor.worldY, startWorldY, case.label .. " returns to its physical anchor")
      local peak = startWorldY
      for _, worldY in ipairs(observed.worldYs) do
        peak = math.max(peak, assert(worldY))
      end
      Assert.isTrue(peak > startWorldY, case.label .. " retains its physical jump arc")
      Assert.isTrue(
        peak <= startWorldY + MovementCalibration.JUMP_HEIGHTS[case.action.distance] + 1e-9,
        case.label .. " retains its calibrated jump height"
      )
    end
  end
end

function T.half_rate_locomotion_keeps_integer_continuous_pose_phase()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.half_rate_chain",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.walkInPlace({ direction = "east", speed = "slow", count = 2 }),
          S.m.delay({ ticks = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  local startingPoseTick = actor.poseTick
  local sawBob = false
  for progress = 1, 32 do
    h.scheduler:step(100 + progress, nil)
    local expectedPose = "walk"
    if progress == 16 or progress == 32 then
      expectedPose = "idle"
    end
    Assert.equal(actor.pose, expectedPose, "half-rate actions settle at their completed boundaries")
    Assert.equal(actor.poseTick, startingPoseTick + math.floor(progress / 2), "half-rate pose phase stays contiguous")
    Assert.equal(actor.poseTick, math.floor(actor.poseTick), "half-rate pose phase remains an integer")
    Assert.isTrue(actor.poseTick >= 0, "half-rate pose phase remains non-negative")
    sawBob = sawBob or actor.presentationOffset.y ~= 0
    if progress == 16 then
      Assert.isNil(actor:currentAction(), "the first half-rate action keeps its existing duration")
      Assert.equal(actor.poseTick, startingPoseTick + 8, "the first half-rate action ends at its exact rational delta")
    elseif progress < 32 then
      Assert.equal(actor:currentAction(), "walk_in_place", "the repeated half-rate action remains active")
    end
  end
  Assert.isNil(actor:currentAction(), "the second half-rate action keeps its existing duration")
  Assert.equal(actor.poseTick, startingPoseTick + 16, "two half-rate actions have no fractional drift")
  Assert.isTrue(sawBob, "raw action progress still drives walk-in-place bob")
  Assert.equal(actor.presentationOffset.y, 0, "the second half-rate action clears its bob")
end

function T.supported_locomotion_profiles_have_explicit_pose_cadence()
  local progressTicks = 14
  local expectedWalk = {
    slower = 14,
    slow = 7,
    normal = 14,
    fast = 28,
    faster = 14,
    slightly_fast = 18,
    slightly_faster = 14,
    fastest = 14,
    run = 28,
    hgss_96 = 14,
    hgss_97 = 14,
    hgss_98 = 14,
    hgss_99 = 14,
  }
  local expectedJump = {
    slower = 14,
    slow = 7,
    normal = 14,
    fast = 14,
    faster = 14,
    slightly_fast = 14,
    slightly_faster = 14,
    fastest = 14,
    run = 14,
    hgss_96 = 14,
    hgss_97 = 14,
    hgss_98 = 14,
    hgss_99 = 14,
  }

  Assert.throws(function()
    MovementCalibration.poseProgressTicks({ action = "walk", speed = "impossible" }, progressTicks)
  end, "an unsupported walk speed must fail instead of inheriting one-unit cadence")

  for _, speed in ipairs(Schema.ENUMS.speed) do
    Assert.equal(
      MovementCalibration.poseProgressTicks({ action = "walk", speed = speed }, progressTicks),
      expectedWalk[speed],
      speed .. " walk cadence is explicit"
    )
    Assert.equal(
      MovementCalibration.poseProgressTicks({ action = "jump", distance = "far", speed = speed }, progressTicks),
      expectedJump[speed],
      speed .. " jump cadence is explicit"
    )
  end

  Assert.equal(
    MovementCalibration.poseProgressTicks({ action = "walk", speed = "slightly_fast" }, 0),
    0,
    "slightly_fast starts at zero pose progress"
  )
  Assert.equal(
    MovementCalibration.poseProgressTicks({ action = "walk", speed = "slightly_fast" }, 7),
    9,
    "slightly_fast cadence repeats beyond one period"
  )
end

function T.normal_and_fast_locomotion_keep_independent_pose_cadence()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.cadence",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.walkInPlace({ direction = "east", speed = "normal" }),
          S.m.delay({ ticks = 1 }),
          S.m.walkInPlace({ direction = "east", speed = "fast" }),
          S.m.delay({ ticks = 1 }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  local visual = cadenceVisual()
  local fieldX, fieldZ = actor.fieldX, actor.fieldZ
  local worldX, worldY, worldZ = actor.worldX, actor.worldY, actor.worldZ
  local normalFrames, fastFrames = {}, {}
  local normalSawBob = false

  for tick = 101, 108 do
    h.scheduler:step(tick, nil)
    if tick < 108 then
      Assert.equal(actor:currentAction(), "walk_in_place", "normal walk-in-place remains active")
    else
      Assert.isNil(actor:currentAction(), "the normal action commits on its final fixed tick")
    end
    Assert.equal(actor.poseTick, tick - 100, "normal locomotion advances the pose clock at 1x")
    normalFrames[#normalFrames + 1] =
      assert(FieldActorPose.frameIndex(visual, actor.facing, actor.pose, actor.poseTick))
    Assert.equal(actor.fieldX, fieldX, "normal walk-in-place keeps logical X fixed")
    Assert.equal(actor.fieldZ, fieldZ, "normal walk-in-place keeps logical Z fixed")
    Assert.equal(actor.worldX, worldX, "normal walk-in-place keeps world X at its anchor")
    Assert.equal(actor.worldY, worldY, "normal walk-in-place keeps world Y at its anchor")
    Assert.equal(actor.worldZ, worldZ, "normal walk-in-place keeps world Z at its anchor")
    normalSawBob = normalSawBob or actor.presentationOffset.y ~= 0
  end
  Assert.deepEqual(normalFrames, { 4, 4, 4, 4, 5, 5, 5, 4 }, "normal cadence selects the source timeline at 1x")
  Assert.isTrue(normalSawBob, "normal walk-in-place retains its bob during the calibrated action")
  Assert.equal(actor.presentationOffset.y, 0, "normal walk-in-place bob ends at its calibrated duration")

  h.scheduler:step(109, nil)
  Assert.equal(actor.pose, "idle", "the delay uses the visual idle presentation")
  Assert.equal(actor.poseTick, 8, "the delay does not advance static idle")

  local fastSawBob = false
  for tick = 110, 113 do
    h.scheduler:step(tick, nil)
    if tick < 113 then
      Assert.equal(actor:currentAction(), "walk_in_place", "fast walk-in-place remains active")
    else
      Assert.isNil(actor:currentAction(), "the fast action commits on its final fixed tick")
    end
    Assert.equal(
      actor.poseTick,
      8 + 2 * (tick - 109),
      "fast locomotion advances the pose clock at 2x (got " .. actor.poseTick .. ")"
    )
    fastFrames[#fastFrames + 1] = assert(FieldActorPose.frameIndex(visual, actor.facing, actor.pose, actor.poseTick))
    Assert.equal(actor.fieldX, fieldX, "fast walk-in-place keeps logical X fixed")
    Assert.equal(actor.fieldZ, fieldZ, "fast walk-in-place keeps logical Z fixed")
    Assert.equal(actor.worldX, worldX, "fast walk-in-place keeps world X at its anchor")
    Assert.equal(actor.worldY, worldY, "fast walk-in-place keeps world Y at its anchor")
    Assert.equal(actor.worldZ, worldZ, "fast walk-in-place keeps world Z at its anchor")
    fastSawBob = fastSawBob or actor.presentationOffset.y ~= 0
  end
  Assert.deepEqual(fastFrames, { 5, 5, 5, 4 }, "fast cadence selects the source timeline at 2x")
  Assert.isTrue(fastSawBob, "fast walk-in-place retains its bob during the calibrated action")
  Assert.equal(actor.presentationOffset.y, 0, "fast walk-in-place bob ends at its calibrated duration")
  h.scheduler:step(114, nil)
  Assert.isNil(actor:currentAction(), "the trailing delay completes at its calibrated boundary")
end

function T.animation_pause_suppresses_normal_and_fast_pose_cadence()
  local function assertPaused(speed)
    local h = harness()
    local resource = S.script({
      api = 1,
      id = "test.paused_" .. speed,
      steps = {
        S.applyMovement({
          actor = ACTOR_ID,
          movement = {
            S.m.pauseAnimation(),
            S.m.walkInPlace({ direction = "east", speed = speed }),
          },
        }),
        S.waitMovement(),
        S.stop(),
      },
    })
    startForeground(h, resource, 100)
    h.scheduler:step(100, nil)
    local actor = assert(h.mgr:getById(ACTOR_ID))
    local durationTicks = MovementCalibration.actionTicks({ action = "walk_in_place", speed = speed })
    local initialPoseTick = actor.poseTick
    for progress = 1, durationTicks do
      h.scheduler:step(100 + progress, nil)
      Assert.isTrue(actor.animationPaused, speed .. " walk-in-place remains paused")
      Assert.equal(actor.poseTick, initialPoseTick, speed .. " paused walk-in-place does not advance pose phase")
    end
    Assert.isNil(actor:currentAction(), speed .. " paused walk-in-place still completes at its calibrated duration")
  end

  assertPaused("normal")
  assertPaused("fast")
end

return { tests = T }
