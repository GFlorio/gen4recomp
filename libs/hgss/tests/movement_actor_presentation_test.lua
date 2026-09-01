-- Scripted-actor presentation lifecycle: proves facing/pose transitions on
-- the real FieldObjectActor driven through the production
-- Scheduler/MovementTask/ScriptActorWorld/FieldActorManager wiring (not the
-- script-facing FakeActors fake), since the reported stale-walk-pose defect
-- only reproduces through that composition.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
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

local function fakeAssets()
  return {
    knows = function()
      return true
    end,
    acquire = function(_, id)
      return { spriteId = id }
    end,
    release = function() end,
  }
end

-- Wires the real production actor stack (FieldActorManager -> ScriptActorWorld)
-- behind the same Scheduler/MovementTask machinery movement_test.lua exercises
-- against FakeActors, so presentation state (facing/pose) is observed on the
-- concrete FieldObjectActor a production renderer would read.
local function harness()
  local mgr = FieldActorManager.new({ assets = fakeAssets(), policy = POLICY })
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

-- `walk -> delay -> face` (fast walk = 4 ticks, a 3-tick delay, and an
-- immediate face) keeps each timed action on its own scheduler boundary.
-- Presentation pose must settle to idle when the delay begins, not carry the
-- completed walk's pose through the later delay ticks.
function T.walk_then_delay_then_face_settles_idle_once_the_walk_ends()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.settle",
    steps = {
      S.applyMovement({
        actor = ACTOR_ID,
        movement = {
          S.m.walk({ direction = "east", speed = "fast", tiles = 1 }),
          S.m.delay({ ticks = 3 }),
          S.m.face({ direction = "south" }),
        },
      }),
      S.waitMovement(),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local actor = assert(h.mgr:getById(ACTOR_ID))
  for tick = 101, 103 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor.pose, "walk", "the walk action must show walking presentation on tick " .. tick)
  end
  -- The walk's final tick (104) commits. The delay begins on the next poll,
  -- so the completed walk remains the observable presentation for tick 104.
  h.scheduler:step(104, nil)
  Assert.equal(actor.pose, "walk", "the completed walk remains visible on its boundary tick")
  h.scheduler:step(105, nil)
  Assert.equal(actor.pose, "idle", "delay must never carry a stale walking pose")
  h.scheduler:step(106, nil)
  Assert.equal(actor.pose, "idle", "delay must remain idle while it advances")
  -- Tick 107 completes the delay. The face begins on tick 108, then the
  -- exhausted plan settles in that same poll.
  h.scheduler:step(107, nil)
  Assert.equal(actor.pose, "idle", "the completed delay remains idle on its boundary tick")
  h.scheduler:step(108, nil)
  Assert.equal(actor.pose, "idle", "face must not create or inherit a walking pose")
  Assert.equal(actor.facing, "south", "the face action still applies its facing")
end

-- `walk -> walk -> walk_in_place (two repetitions) -> delay` (all "fast", 4
-- ticks per action) must present one continuous locomotion pose across every
-- timed boundary. Each walk-in-place repetition gets a fresh action
-- transaction and leaves no residual presentation offset when it commits.
function T.contiguous_locomotion_stays_continuous_then_settles_at_the_first_non_locomotion_boundary()
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
    Assert.equal(actor.pose, "walk", "the locomotion chain must show no idle flash at tick " .. tick)
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
  Assert.equal(actor.presentationOffset.y, 0, "the second commit clears its bob")
  Assert.equal(
    actor.poseTick,
    poseTickBeforeWalkInPlace + 16,
    "two fast repetitions retain their full calibrated bob duration"
  )
  Assert.equal(actor.worldX, worldX, "the second completed walk-in-place keeps world X at its anchor")
  Assert.equal(actor.worldY, worldY, "the second completed walk-in-place keeps world Y at its anchor")
  Assert.equal(actor.worldZ, worldZ, "the second completed walk-in-place keeps world Z at its anchor")
  -- The trailing delay begins on the following poll.
  h.scheduler:step(117, nil)
  Assert.equal(actor.pose, "idle", "pose settles when the trailing delay begins")
  h.scheduler:step(118, nil)
  Assert.equal(actor.pose, "idle", "the sequence's completion must not leave a stale walking pose")
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
  -- observable walking presentation for this boundary tick.
  h.scheduler:step(108, nil)
  Assert.isNil(actor:currentAction(), "walk_in_place has committed by its boundary tick")
  Assert.equal(actor.pose, "walk", "the completed walk_in_place remains visible on its boundary tick")
  Assert.equal(actor.fieldX, fieldX, "walk_in_place's boundary tick keeps logical fieldX fixed")
  Assert.equal(actor.fieldZ, fieldZ, "walk_in_place's boundary tick keeps logical fieldZ fixed")

  -- Tick 109: the trailing delay settles every locomotion-style presentation
  -- back to idle.
  h.scheduler:step(109, nil)
  Assert.equal(actor.pose, "idle", "the sequence settles to idle once the delay begins")
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
  Assert.deepEqual(normalFrames, { 4, 4, 4, 4, 5, 5, 5, 5 }, "normal cadence selects the source timeline at 1x")
  Assert.isTrue(normalSawBob, "normal walk-in-place retains its bob during the calibrated action")
  Assert.equal(actor.presentationOffset.y, 0, "normal walk-in-place bob ends at its calibrated duration")

  h.scheduler:step(109, nil)
  Assert.equal(actor.pose, "idle", "the delay settles the normal walk-in-place before fast starts")
  Assert.equal(actor.poseTick, 0, "the delay resets the idle pose phase")

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
      2 * (tick - 109),
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
  Assert.deepEqual(fastFrames, { 4, 4, 5, 5 }, "fast cadence selects the source timeline at 2x")
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
