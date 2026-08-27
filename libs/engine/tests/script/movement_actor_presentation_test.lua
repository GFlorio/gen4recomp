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
-- immediate face) chains within the scheduler's own same-tick continuation:
-- the walk's completing tick already begins the delay, and the delay's
-- completing tick already begins and finishes the face. Presentation pose
-- must settle to idle exactly when the walk ends, not continue to read
-- "walk" through the delay and face that follow.
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
  -- The walk's final tick (104) commits and the chained delay begins in the
  -- same tick; the actor must already read idle, not carry the walk pose.
  h.scheduler:step(104, nil)
  Assert.equal(actor.pose, "idle", "pose must settle to idle once the walk ends and delay begins")
  h.scheduler:step(105, nil)
  Assert.equal(actor.pose, "idle", "delay must never carry a stale walking pose")
  -- Tick 106 completes the delay and chains straight through the immediate
  -- face action to sequence completion, all in the same tick.
  h.scheduler:step(106, nil)
  Assert.equal(actor.pose, "idle", "face must not create or inherit a walking pose")
  Assert.equal(actor.facing, "south", "the face action still applies its facing")
end

-- `walk -> walk -> walk_in_place -> delay` (all "fast", 4 ticks per action)
-- must present one continuous locomotion pose across every boundary between
-- the three locomotion actions, then settle to idle exactly when the trailing
-- delay begins.
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
          S.m.walkInPlace({ direction = "east", speed = "fast", count = 1 }),
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
  for tick = 101, 109 do
    h.scheduler:step(tick, nil)
    Assert.equal(actor.pose, "walk", "the locomotion chain must show no idle flash at tick " .. tick)
  end
  -- Tick 110 commits the walk_in_place action and chains straight into the
  -- trailing delay; presentation must settle to idle in that same tick.
  h.scheduler:step(110, nil)
  Assert.equal(actor.pose, "idle", "pose must settle to idle exactly when locomotion ends")
  h.scheduler:step(111, nil)
  Assert.equal(actor.pose, "idle", "the sequence's completion must not leave a stale walking pose")
end

return { tests = T }
