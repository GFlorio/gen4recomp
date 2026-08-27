-- Scripted-actor presentation lifecycle: proves facing/pose transitions on
-- the real FieldObjectActor driven through the production
-- Scheduler/MovementTask/ScriptActorWorld/FieldActorManager wiring (not the
-- script-facing FakeActors fake), since the reported stale-walk-pose defect
-- only reproduces through that composition.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
local MovementTask = require("libs.engine.src.script.tasks.MovementTask")
local MovementBarrierTask = require("libs.engine.src.script.tasks.MovementBarrierTask")
local FakeServices = require("tests.support.script.FakeServices")
local ScriptActorWorld = require("libs.engine.src.script.ScriptActorWorld")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

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
  return {
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
            movement = 0,
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
  local world = ScriptActorWorld.new(mgr, player)
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
  local sawBob = false
  for tick = 109, 111 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor:currentAction(), "walk_in_place", "the first walk-in-place instance is active")
    Assert.equal(actor.pose, "walk", "walk-in-place uses walking presentation")
    Assert.equal(actor.fieldX, fieldX, "walk-in-place keeps logical X fixed")
    Assert.equal(actor.fieldZ, fieldZ, "walk-in-place keeps logical Z fixed")
    sawBob = sawBob or actor.presentationOffset.y ~= 0
  end
  Assert.isTrue(sawBob, "walk-in-place visibly bobs during its action")
  -- The first walk-in-place repetition commits at 112's boundary. Its
  -- transaction clears the bob, and the second repetition begins on the next
  -- poll with a fresh presentation offset.
  h.scheduler:step(112, nil)
  Assert.isNil(actor:currentAction(), "a completed walk-in-place yields before its repetition")
  Assert.equal(actor.presentationOffset.y, 0, "a committed walk-in-place clears its bob")
  h.scheduler:step(113, nil)
  Assert.equal(actor:currentAction(), "walk_in_place", "the second walk-in-place instance starts next poll")
  Assert.isTrue(actor.presentationOffset.y ~= 0, "the second instance gets a fresh bob")
  Assert.equal(actor.fieldX, fieldX, "the second walk-in-place keeps logical X fixed")
  Assert.equal(actor.fieldZ, fieldZ, "the second walk-in-place keeps logical Z fixed")
  for tick = 114, 115 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor.pose, "walk", "the second walk-in-place remains walking")
    Assert.equal(actor.fieldX, fieldX, "the second walk-in-place keeps logical X fixed")
    Assert.equal(actor.fieldZ, fieldZ, "the second walk-in-place keeps logical Z fixed")
  end
  h.scheduler:step(116, nil)
  Assert.isNil(actor:currentAction(), "the second walk-in-place commits independently")
  Assert.equal(actor.presentationOffset.y, 0, "the second commit clears its bob")
  -- The trailing delay begins on the following poll.
  h.scheduler:step(117, nil)
  Assert.equal(actor.pose, "idle", "pose settles when the trailing delay begins")
  h.scheduler:step(118, nil)
  Assert.equal(actor.pose, "idle", "the sequence's completion must not leave a stale walking pose")
end

return { tests = T }
