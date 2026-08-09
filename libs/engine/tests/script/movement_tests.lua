-- Movement task tests : the movement plan
-- machine, environment-generation barriers, actor-scoped barriers, multiple
-- actors started before one barrier, movement save/resume, facing locks,
-- ownership conflicts, cancellation, and the background no-player-movement
-- rule. Elm's source-facing movement and one multi-actor
-- movement fixture work.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
local MovementTask = require("libs.engine.src.script.tasks.MovementTask")
local MovementBarrierTask = require("libs.engine.src.script.tasks.MovementBarrierTask")
local MovementPauseTask = require("libs.engine.src.script.tasks.MovementPauseTask")
local FakeServices = require("tests.support.script.FakeServices")
local Diagnostics = require("libs.engine.src.script.Diagnostics")

local T = {}

---@class MovementHarness
---@field services FakeServices
---@field registry Registry
---@field composition Composition
---@field taskRegistry TaskRegistry
---@field scheduler Scheduler
---@field trace Diagnostics.TraceRecorder

---@return MovementHarness
local function harness()
  local services = FakeServices.new()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("movement", 1, MovementTask)
  taskRegistry:register("movement_barrier", 1, MovementBarrierTask)
  taskRegistry:register("movement_pause", 1, MovementPauseTask)
  local recorder = Diagnostics.newTraceRecorder()
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    taskRegistry = taskRegistry,
    scheduler = scheduler,
    trace = recorder,
  }
end

---@param h MovementHarness
---@param resource table
---@param tick integer
---@return string instanceId
local function startForeground(h, resource, tick)
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, nil, tick)
end

local function script(id, stepsOrSpec)
  if type(stepsOrSpec) == "table" and stepsOrSpec.steps ~= nil then
    stepsOrSpec.api = 1
    stepsOrSpec.id = id
    return S.script(stepsOrSpec)
  end
  return S.script({ api = 1, id = id, steps = stepsOrSpec })
end

-- 1. apply_movement starts asynchronous movement and continues the same
-- tick; the actor's position advances per poll; the environment barrier
-- completes when the generation empties .
T["apply movement and barrier"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.move", {
    S.applyMovement({
      actor = "elm",
      movement = {
        S.m.face({ direction = "south" }),
        S.m.walk({ direction = "east", speed = "normal", tiles = 2 }),
      },
    }),
    S.waitMovement(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  -- The movement task was created this tick; the plan starts on its first
  -- poll (the next tick).
  local elm = h.services.actors.actors.elm
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(101, nil)
  local envId = assert(h.scheduler:foregroundEnvironmentId())
  Assert.notNil(
    h.scheduler:activeMovementForActor(envId, "elm"),
    "the movement task owns the actor after its first poll"
  )
  -- Each poll advances one plan tick: face (1) + 2 walk tiles x 8 ticks = 17
  -- plan ticks. The barrier completes on the poll after the generation
  -- empties, and continuation follows one tick later.
  for tick = 102, 117 do
    h.scheduler:step(tick, nil)
  end
  -- The last plan tick lands at 117's poll: the actor reaches its
  -- destination and the generation empties; the barrier polls after the
  -- movement task in the same loop, observes the empty generation, and
  -- completes (resume_pending for 118). Continuation follows at 118.
  Assert.equal(elm.fieldX, 6, "the actor reaches its destination after 17 plan ticks")
  Assert.equal(elm.facing, "east")
  h.scheduler:step(118, nil)
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    1,
    "a successful barrier poll never continues the graph in its own tick"
  )
end

-- 2. Multiple actors started before one barrier .
T["multiple actors before one barrier"] = function()
  local h = harness()
  h.services.actors:add("a", { fieldX = 0, fieldZ = 0, facing = "south" })
  h.services.actors:add("b", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource = script("test.multi", {
    S.applyMovement({ actor = "a", movement = { S.m.walk({ direction = "east", speed = "fast", tiles = 1 }) } }),
    S.applyMovement({ actor = "b", movement = { S.m.walk({ direction = "north", speed = "fast", tiles = 1 }) } }),
    S.waitMovement(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  for tick = 101, 104 do
    h.scheduler:step(tick, nil)
  end
  -- Both actors move in parallel: 4 plan ticks (fast walk) from 101..104.
  -- The barrier's poll at 104 observes the emptied generation (it polls
  -- after the movement tasks in the same loop) and marks the owner
  -- resume_pending; continuation follows at 105.
  h.scheduler:step(105, nil)
  Assert.equal(h.services.actors.actors.a.fieldX, 1)
  Assert.equal(h.services.actors.actors.b.fieldZ, -1)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 3. Empty WaitMovement still has the native-style minimum timing
-- : create at T, poll at T+1, continuation at T+2.
T["empty barrier timing"] = function()
  local h = harness()
  local resource = script("test.empty", {
    S.waitMovement(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 4. Actor-scoped barrier waits only for its actors (handwritten scripts).
T["actor scoped barrier"] = function()
  local h = harness()
  h.services.actors:add("a", { fieldX = 0, fieldZ = 0, facing = "south" })
  h.services.actors:add("b", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource = script("test.scoped", {
    S.applyMovement({ actor = "a", movement = { S.m.walk({ direction = "east", speed = "fast", tiles = 1 }) } }),
    S.applyMovement({ actor = "b", movement = { S.m.walk({ direction = "east", speed = "normal", tiles = 1 }) } }),
    S.waitMovement({ scope = "actors", actors = { "a" } }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  for tick = 101, 104 do
    h.scheduler:step(tick, nil)
  end
  -- a finished at 104's poll (4 plan ticks); the scoped barrier completes
  -- at 105's poll; continuation at 106 while b still moves.
  h.scheduler:step(105, nil)
  h.scheduler:step(106, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  Assert.equal(h.services.actors.actors.b.fieldX, 0)
end

-- 5. Facing locks and immediate actions apply.
T["facing lock and immediate actions"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.face", {
    S.applyMovement({
      actor = "elm",
      movement = {
        S.m.lockFacing(),
        S.m.face({ direction = "south" }),
        S.m.walk({ direction = "east", speed = "normal", tiles = 1 }),
      },
    }),
    S.waitMovement(),
    S.stop(),
  })
  startForeground(h, resource, 100)
  for tick = 101, 110 do
    h.scheduler:step(tick, nil)
  end
  local elm = h.services.actors.actors.elm
  Assert.equal(elm.facing, "north", "facing is locked during the walk")
  Assert.equal(elm.fieldX, 5)
end

-- 6. Save/resume mid-movement: the plan, destination, and generation state
-- restore exactly .
T["movement save resume"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.savemove", {
    S.applyMovement({
      actor = "elm",
      movement = {
        S.m.walk({ direction = "east", speed = "normal", tiles = 2 }),
      },
    }),
    S.waitMovement(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  local bucket = ScriptSave.capture(h.scheduler, 102, { registryFingerprint = h.registry:fingerprint() })
  local recorder = Diagnostics.newTraceRecorder()
  local scheduler2 = Scheduler.new({
    services = h.services,
    taskRegistry = h.taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  ScriptSave.restore(bucket, scheduler2, 102, {})
  for tick = 103, 122 do
    scheduler2:step(tick, nil)
  end
  Assert.equal(h.services.actors.actors.elm.fieldX, 6)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 7. Movement ownership: two foreground tasks cannot own the same actor
--  — the second apply_movement faults.
T["conflicting movement ownership"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.conflict", {
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local instance = assert(h.scheduler:instance(instanceId))
  Assert.equal(instance.status, "faulted")
end

-- 8. Missing actors are attributed errors.
T["missing movement actor"] = function()
  local h = harness()
  local resource = script("test.ghost", {
    S.applyMovement({ actor = "ghost", movement = { S.m.walk({ direction = "east" }) } }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.scheduler:instance(instanceId)).endReason, "SCRIPT_ACTOR_NOT_FOUND")
end

-- 9. Background scripts may not move the player .
T["background cannot move player"] = function()
  local h = harness()
  h.services.actors:add("player", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.bg", {
    S.applyMovement({ actor = "player", movement = { S.m.walk({ direction = "east" }) } }),
    S.stop(),
  })
  h.registry:installBase(resource.id, resource, "generated")
  local composed = assert(h.composition:effective(resource.id))
  local instanceId = h.scheduler:createBackground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.scheduler:instance(instanceId)).endReason, "SCRIPT_BACKGROUND_FORBIDDEN")
end

-- 10. Cancellation releases movement ownership .
T["cancellation releases movement"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.cancelmove", {
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.waitMovement(),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local envId = assert(h.scheduler:foregroundEnvironmentId())
  h.scheduler:cancelEnvironment(envId, "cancelled")
  Assert.isNil(h.scheduler:activeMovementForActor(envId, "elm"))
  local elm = h.services.actors.actors.elm
  Assert.equal(elm.fieldX, 4, "cancellation freezes the actor's position")
end

-- 11. lock_all with outstanding movement pauses until the movement reaches a
-- pausable boundary (a slow walk runs 16 plan ticks) instead of yielding.
T["lock all pauses when movement outstanding"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.lockpause", {
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.lockAll(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  for tick = 101, 115 do
    h.scheduler:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "lock_all blocks while the walk is mid-step")
  -- The 16th poll (tick 116) completes the walk; the pause task observes the
  -- empty generation and resumes for 117; continuation follows at 117.
  h.scheduler:step(116, nil)
  h.scheduler:step(117, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 12. lock_actor(waitUntilPausable) blocks on the actor's own movement and
-- completes once the actor is at a pausable boundary.
T["lock actor waits for pausable boundary"] = function()
  local h = harness()
  h.taskRegistry:register("actor_pause", 1, MovementPauseTask)
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.lockactorpause", {
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "fast", tiles = 1 }) } }),
    S.lockActor({ actor = "elm", waitUntilPausable = true }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "mid-walk is not pausable")
  -- fast walk runs 4 plan ticks: boundary at poll 104, continuation at 105.
  for tick = 102, 103 do
    h.scheduler:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(104, nil)
  h.scheduler:step(105, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 13. An actor-scoped barrier created through the compiler's canonical
-- actor-ref tables (not raw strings) resolves the references and freezes the
-- matching movement task ids.
T["actor scoped barrier with canonical refs"] = function()
  local h = harness()
  h.services.actors:add("a", { fieldX = 0, fieldZ = 0, facing = "south" })
  h.services.actors:add("b", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource = script("test.scopedrefs", {
    S.applyMovement({ actor = "a", movement = { S.m.walk({ direction = "east", speed = "fast", tiles = 1 }) } }),
    S.applyMovement({ actor = "b", movement = { S.m.walk({ direction = "east", speed = "normal", tiles = 1 }) } }),
    S.waitMovement({ scope = "actors", actors = { S.actor("a") } }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  -- a finishes its fast walk at 104's poll; the scoped barrier resumes at
  -- 105 and continues at 106 while b still walks.
  for tick = 101, 103 do
    h.scheduler:step(tick, nil)
  end
  h.scheduler:step(104, nil)
  h.scheduler:step(105, nil)
  h.scheduler:step(106, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  Assert.equal(h.services.actors.actors.b.fieldX, 0, "b is not watched by the barrier")
end

return T
