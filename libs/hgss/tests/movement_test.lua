-- Movement task tests : the movement plan
-- machine, environment-generation barriers, actor-scoped barriers, multiple
-- actors started before one barrier, movement save/resume, facing locks,
-- ownership conflicts (blocking and nonblocking forms), cancellation, and
-- the background no-player-movement rule. Elm's source-facing
-- movement and one multi-actor movement fixture work.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptSave = require("libs.script.src.ScriptSave")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local ChildScriptTask = require("libs.script.src.tasks.ChildScriptTask")
---@cast ChildScriptTask TaskImplementation
local MovementTask = require("libs.hgss.src.script.tasks.MovementTask")
---@cast MovementTask TaskImplementation
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local MovementBarrierTask = require("libs.hgss.src.script.tasks.MovementBarrierTask")
---@cast MovementBarrierTask TaskImplementation
local MovementPauseTask = require("libs.hgss.src.script.tasks.MovementPauseTask")
---@cast MovementPauseTask TaskImplementation
local FakeServices = require("tests.support.script.FakeServices")
local Diagnostics = require("libs.script.src.Diagnostics")

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
  -- The conflicting-blocking-move test drives its common child via call_common.
  taskRegistry:register("child_script", 1, ChildScriptTask)
  taskRegistry:register("movement", 1, MovementTask)
  taskRegistry:register("movement_barrier", 1, MovementBarrierTask)
  taskRegistry:register("movement_pause", 1, MovementPauseTask)
  local recorder = Diagnostics.newTraceRecorder()
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
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

T["repeated one-tick actions advance one instance per poll"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local instanceId = startForeground(h, script("test.repeated_face", { S.waitTicks({ ticks = 20 }) }), 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("movement", {
    actor = "elm",
    sequence = { { action = "face", direction = "east", count = 5 } },
    blocking = true,
  }, instance, 100, nil)

  local task = assert(h.scheduler:taskById(taskId))
  for repetition = 1, 5 do
    h.scheduler:step(100 + repetition, nil)
    Assert.equal(
      h.services.actors.actors.elm.facing,
      "east",
      "face poll "
        .. repetition
        .. " status="
        .. task.status
        .. " index="
        .. task.state.actionIndex
        .. " repeat="
        .. task.state.actionRepeat
    )
    if repetition < 5 then
      Assert.equal(task.status, "active", "a repeated face remains active before its final instance")
      Assert.equal(task.state.actionIndex, 0)
      Assert.equal(task.state.actionRepeat, repetition)
    else
      Assert.equal(task.status, "completed", "the fifth face instance completes on the fifth poll")
      Assert.equal(task.state.actionIndex, 1)
      Assert.equal(task.state.actionRepeat, 0)
      Assert.equal(task.completedAtTick, 105)
    end
  end
end

T["timed completion yields successors while final completion settles"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local instanceId = startForeground(h, script("test.timed_successor", { S.waitTicks({ ticks = 20 }) }), 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("movement", {
    actor = "elm",
    sequence = {
      { action = "face", direction = "east" },
      { action = "set_visible", visible = false },
      { action = "face", direction = "south" },
    },
    blocking = true,
  }, instance, 100, nil)
  local task = assert(h.scheduler:taskById(taskId))
  h.scheduler:step(101, nil)
  Assert.equal(task.status, "active", "a timed completion leaves successor work for the next poll")
  Assert.equal(task.state.actionIndex, 1)
  Assert.equal(task.state.actionRepeat, 0)
  Assert.equal(h.services.actors.actors.elm.facing, "east")
  Assert.isTrue(h.services.actors.actors.elm.visible, "the immediate successor must not run on the completion poll")

  h.scheduler:step(102, nil)
  Assert.equal(task.status, "completed")
  Assert.equal(h.services.actors.actors.elm.facing, "south")
  Assert.isFalse(h.services.actors.actors.elm.visible)

  local final = harness()
  final.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local finalInstanceId = startForeground(final, script("test.final_timed", { S.waitTicks({ ticks = 20 }) }), 100)
  local finalInstance = assert(final.scheduler:instance(finalInstanceId))
  local finalTaskId = final.scheduler:createTask("movement", {
    actor = "elm",
    sequence = { { action = "face", direction = "west" } },
    blocking = true,
  }, finalInstance, 100, nil)
  final.scheduler:step(101, nil)
  local finalTask = assert(final.scheduler:taskById(finalTaskId))
  Assert.equal(finalTask.status, "completed", "a final timed action settles on its completion poll")
  Assert.isNil(final.scheduler:activeMovementForActor(assert(final.scheduler:foregroundEnvironmentId()), "elm"))
  Assert.isFalse(assert(final.scheduler:environments()[1]):hasOutstandingMovement())
  Assert.equal(final.services.actors.actors.elm.facing, "west")
end

T["immediate-only movement plans finish in one poll"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local instanceId = startForeground(h, script("test.immediate_only", { S.waitTicks({ ticks = 20 }) }), 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("movement", {
    actor = "elm",
    sequence = {
      { action = "set_visible", visible = false },
      { action = "lock_facing" },
      { action = "unlock_facing" },
      { action = "pause_animation" },
      { action = "resume_animation" },
    },
    blocking = true,
  }, instance, 100, nil)

  h.scheduler:step(101, nil)
  local task = assert(h.scheduler:taskById(taskId))
  Assert.equal(task.status, "completed", "immediate operations may chain and settle in one poll")
  Assert.isFalse(h.services.actors.actors.elm.visible)
  Assert.isFalse(h.services.actors.actors.elm.animationPaused)
  Assert.isNil(h.scheduler:activeMovementForActor(assert(h.scheduler:foregroundEnvironmentId()), "elm"))
end

T["immediate prelude starts one timed action in the same poll"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local instanceId = startForeground(h, script("test.immediate_prelude", { S.waitTicks({ ticks = 20 }) }), 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("movement", {
    actor = "elm",
    sequence = {
      { action = "set_visible", visible = false },
      { action = "face", direction = "east", count = 2 },
    },
    blocking = true,
  }, instance, 100, nil)

  h.scheduler:step(101, nil)
  local task = assert(h.scheduler:taskById(taskId))
  Assert.equal(task.status, "active", "the first timed instance follows the immediate prelude")
  Assert.equal(task.state.actionIndex, 1)
  Assert.equal(task.state.actionRepeat, 1)
  Assert.isFalse(h.services.actors.actors.elm.visible)
  Assert.equal(h.services.actors.actors.elm.facing, "east")

  h.scheduler:step(102, nil)
  Assert.equal(task.status, "completed", "the repeated timed action finishes on its second poll")
end

-- 1. apply_movement starts asynchronous movement and continues the same
-- tick; the actor's position advances per poll; the environment barrier
-- completes when the generation empties.
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

-- 2. Multiple actors started before one barrier.
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

T["lowered local object zero and player can move concurrently"] = function()
  local h = harness()
  h.services.actors:add("mom", { fieldX = 4, fieldZ = 6, facing = "north" })
  h.services.actors:add("player", { fieldX = 5, fieldZ = 6, facing = "north" })
  h.services.actors.mapIndexes = { [0] = "mom" }

  local lowered = {
    items = {
      { actor = "mom" },
      { actor = "player" },
    },
  }
  local instanceId = startForeground(h, script("test.lowered_actor_identity", { S.waitTicks({ ticks = 10 }) }), 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local environment = assert(h.scheduler:environments()[1])
  local ctx = { services = h.services, environment = environment, instance = instance, scheduler = h.scheduler }
  local function start(reference)
    local actorId = RuntimeValues.resolveActor(reference, ctx)
    return h.scheduler:createTask(
      "movement",
      { actor = actorId, sequence = { { action = "walk", direction = "east", speed = "normal", tiles = 1 } } },
      instance,
      100,
      nil
    )
  end
  local momTaskId = start(lowered.items[1].actor)
  local playerTaskId = start(lowered.items[2].actor)
  Assert.notNil(momTaskId)
  Assert.notNil(playerTaskId)
  Assert.equal(h.scheduler:activeMovementForActor(environment.environmentId, "mom"), momTaskId)
  Assert.equal(h.scheduler:activeMovementForActor(environment.environmentId, "player"), playerTaskId)
  local ok, err = pcall(function()
    start(lowered.items[2].actor)
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "SCRIPT_ACTOR_BUSY")
end

-- 3. Empty WaitMovement still has the native-style minimum timing:
-- create at T, poll at T+1, continuation at T+2.
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
-- restore exactly.
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
    semantics = require("libs.hgss.src.script.RuntimeValues"),
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
  Assert.notNil(h.services.events:eventFor("script.error", instanceId))
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
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_ACTOR_NOT_FOUND")
end

-- 9. Background scripts may not move the player.
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
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_BACKGROUND_FORBIDDEN")
end

-- 10. Cancellation releases movement ownership.
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

-- 12b. `release_actor` without a matching prior `lock_actor` from this
-- instance is the source standalone-Release semantic (resume the actor's
-- own default autonomous movement); it must complete like any other
-- instruction, not fault as an unowned-lock release.
T["release actor without a prior lock resumes without faulting"] = function()
  local h = harness()
  h.services.actors:add("marill", { fieldX = 4, fieldZ = 6, facing = "north" })
  local instanceId = startForeground(
    h,
    script("test.standalonerelease", {
      S.lockAll(),
      S.releaseActor({ actor = "marill" }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  Assert.isNil(h.services.events:eventFor("script.error", instanceId), "standalone release_actor must not fault")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 12c. Paired `lock_actor`/`release_actor` from the same instance keep their
-- existing ownership accounting: releasing still clears the lock this
-- instance holds.
T["paired lock actor and release actor still clear the held lock"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local instanceId = startForeground(
    h,
    script("test.pairedactorlock", {
      S.lockActor({ actor = "elm", waitUntilPausable = false }),
      S.releaseActor({ actor = "elm" }),
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local env = assert(h.scheduler:environments()[1])
  Assert.equal(env:lockCount("actor:elm"), 0)
  Assert.isNil(h.services.events:eventFor("script.error", instanceId))
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

-- 14. A blocking `move` joins the environment's movement generation: a
-- barrier created in the same tick stays active through the walk, the
-- generation empties exactly at the move's final poll, and the script
-- continues one tick later (a completed blocking move never leaves the
-- generation occupied).
T["blocking move participates in movement barriers"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.blockbarrier", {
    S.move({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local env = assert(h.scheduler:environments()[1])
  local instance = assert(h.scheduler:instance(instanceId))
  -- The blocking task is registered in the current generation: a barrier
  -- created in the same tick must not complete while the walk is mid-plan
  -- (a slow walk runs 16 plan ticks, polls 101..116).
  local barrierId = h.scheduler:createTask("movement_barrier", {}, instance, 100, nil)
  h.scheduler:step(101, nil)
  for tick = 102, 115 do
    h.scheduler:step(tick, nil)
    Assert.equal(
      assert(h.scheduler:taskById(barrierId)).status,
      "active",
      "the barrier waits on the blocking move at tick " .. tick
    )
  end
  Assert.isTrue(env:hasOutstandingMovement(), "the blocking move owns the generation mid-walk")
  Assert.equal(h.services.actors.actors.elm.fieldX, 4, "the walk is still mid-plan")
  -- The move's final poll empties the generation; the barrier completes in
  -- the same poll loop and the script's continuation follows one tick later
  -- (the barrier record is cancelled by the environment teardown when the
  -- script stops, so its completion is asserted before then).
  h.scheduler:step(116, nil)
  Assert.equal(assert(h.scheduler:taskById(barrierId)).status, "completed")
  Assert.isFalse(env:hasOutstandingMovement(), "the completed blocking move left the generation")
  Assert.equal(h.services.actors.actors.elm.fieldX, 5, "the actor reaches its destination")
  h.scheduler:step(117, nil)
  Assert.isTrue(assert(h.services.events:eventFor("script.ended", instanceId)).completed)
end

-- 15. A blocking `move` participates in the actor-busy check: a move that
-- tries to start on an actor another context's movement already owns faults
-- SCRIPT_ACTOR_BUSY instead of creating a second conflicting task. The child
-- faults in the caller's tick (dynamic slot loop); the caller faults on the
-- next tick when its child_script task observes the faulted child.
T["conflicting blocking move is rejected"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local child = script("common.mover", {
    S.move({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.stop(),
  })
  h.registry:installBase(child.id, child, "generated")
  local root = script("test.busymove", {
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.callCommon({ target = "common.mover" }),
    S.stop(),
  })
  local instanceId = startForeground(h, root, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  local fault = assert(
    h.services.events:eventFor("script.error", instanceId),
    "the caller faults when the common child's blocking move conflicts"
  )
  Assert.equal(fault.code, "SCRIPT_ACTOR_BUSY")
  Assert.equal(h.services.actors.actors.elm.fieldX, 4, "the conflicting move never started")
end

-- 16. lock_all sees a blocking movement: the movement_pause task behind
-- lock_all watches the current generation, so a blocking `move` started by
-- the script must hold it incomplete until the walk reaches a pausable
-- boundary (the pause task is created directly because the same-tick
-- overlap cannot arise from one script: a blocking move blocks its own
-- context until it finishes).
T["lock all pauses on blocking movement"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.blockpause", {
    S.move({ actor = "elm", movement = { S.m.walk({ direction = "east", speed = "slow", tiles = 1 }) } }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local env = assert(h.scheduler:environments()[1])
  local instance = assert(h.scheduler:instance(instanceId))
  local pauseId = h.scheduler:createTask("movement_pause", {}, instance, 100, nil)
  for tick = 101, 115 do
    h.scheduler:step(tick, nil)
    Assert.equal(
      assert(h.scheduler:taskById(pauseId)).status,
      "active",
      "the pause task waits on the blocking move at tick " .. tick
    )
  end
  Assert.isTrue(env:hasOutstandingMovement(), "lock_all sees the blocking movement mid-walk")
  -- The move's final poll reaches the pausable boundary and empties the
  -- generation; the pause task completes in the same poll loop and the
  -- script continues one tick later.
  h.scheduler:step(116, nil)
  Assert.equal(assert(h.scheduler:taskById(pauseId)).status, "completed")
  h.scheduler:step(117, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  Assert.equal(h.services.actors.actors.elm.fieldX, 5)
end

-- 18. A directional walk must already show its intended facing on the very
-- first advanced tick of the action, not only once that tile's ticks are
-- exhausted: the observable actor-facing lags the logical action today.
T["directional walk establishes facing before the first advanced tick, not at the end"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "east" })
  local resource = script("test.facingstart", {
    S.applyMovement({
      actor = "elm",
      movement = { S.m.walk({ direction = "north", speed = "slow", tiles = 1 }) },
    }),
    S.waitMovement(),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  -- The first poll of a slow walk (16 ticks/tile) already advances the actor
  -- toward its destination; the actor must already face north on this tick.
  h.scheduler:step(101, nil)
  local elm = h.services.actors.actors.elm
  Assert.equal(elm.facing, "north", "facing must be established before the first advanced movement tick")
  for tick = 102, 116 do
    h.scheduler:step(tick, nil)
  end
  Assert.equal(elm.fieldZ, 5, "the walk still completes its logical displacement north")
end

-- 17. A raw movement task (the ctx.tasks.movement descriptor path, created
-- through the registry exactly as the lua-node handler does) joins the
-- environment's movement generation at creation and rejects a second raw
-- movement on the same actor: raw and compiled movement share one ownership
-- boundary.
T["raw movement task owns the generation and rejects conflicts"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = script("test.rawmove", {
    S.waitTicks({ ticks = 500 }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local env = assert(h.scheduler:environments()[1])
  local spec = {
    actor = "elm",
    sequence = { { action = "walk", direction = "east", speed = "slow", tiles = 1 } },
    blocking = true,
  }
  local firstId = h.scheduler:createTask("movement", spec, instance, 100, nil)
  Assert.notNil(firstId)
  Assert.isTrue(env:hasOutstandingMovement(), "the raw blocking movement registers in the generation")
  local ok, err = pcall(function()
    h.scheduler:createTask("movement", spec, instance, 100, nil)
  end)
  Assert.isFalse(ok, "a second raw movement on the same actor must fault")
  Assert.isTrue(Errors.is(err), "the conflict must be a structured error, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_ACTOR_BUSY")
  -- The first movement still completes and empties the generation (a slow
  -- walk runs 16 plan ticks, polls 101..116).
  for tick = 101, 116 do
    h.scheduler:step(tick, nil)
  end
  Assert.isFalse(env:hasOutstandingMovement(), "the completed raw movement left the generation")
  Assert.equal(h.services.actors.actors.elm.fieldX, 5, "the raw movement plan reached its destination")
end

-- The only source-proven automatic movement-emote sound: exclamation plays
-- SEQ_SE_DP_DECIDE exactly once, at the emote action's start tick, never on
-- a later tick or a second time. An unmapped kind (question, still unproven
-- at this call site) must never touch the audio service at all.
T["exclamation plays its proven sound once at the action start tick"] = function()
  local h = harness()
  h.services.actors:add("marill", { fieldX = 2, fieldZ = 3, facing = "south" })
  local calls = {}
  h.services.audio = {
    play = function(_, effectId)
      calls[#calls + 1] = effectId
    end,
  }
  local resource = script("test.exclaim", { S.stop() })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local spec = {
    actor = "marill",
    sequence = { { action = "emote", name = "exclamation" } },
  }
  h.scheduler:createTask("movement", spec, instance, 100, nil)
  for tick = 101, 100 + MovementCalibration.EMOTE_TICKS do
    h.scheduler:step(tick, nil)
  end
  Assert.equal(#calls, 1, "the exclamation sound plays exactly once")
  Assert.equal(calls[1], "SEQ_SE_DP_DECIDE")
end

T["an unmapped emote kind never touches the audio service"] = function()
  local h = harness()
  h.services.actors:add("marill", { fieldX = 2, fieldZ = 3, facing = "south" })
  h.services.audio = nil
  local resource = script("test.question", { S.stop() })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local spec = {
    actor = "marill",
    sequence = { { action = "emote", name = "question" } },
  }
  local ok, err = pcall(function()
    h.scheduler:createTask("movement", spec, instance, 100, nil)
    for tick = 101, 100 + MovementCalibration.EMOTE_TICKS do
      h.scheduler:step(tick, nil)
    end
  end)
  Assert.isTrue(ok, "an unmapped emote kind must not require the audio service: " .. tostring(err))
end

-- Trajectory cries are gated by fresh visibility at each source checkpoint:
-- hiding after the start cry silences the arrival cry, showing after a
-- silent start enables it, and a service that cannot answer visibility never
-- counts as visible.
T["trajectory cries follow fresh visibility at start and arrival"] = function()
  local segment =
    { action = "trajectory_segment", deltaX = 0, deltaZ = 0, surfaceBandDelta = 0, ticks = 2, direction = "south" }
  local h = harness()
  h.services.actors:add("beast", { fieldX = 0, fieldZ = 0, facing = "south" })
  local calls = {}
  h.services.audio = {
    play = function(_, effectId)
      calls[#calls + 1] = effectId
    end,
  }
  local resource = script("test.beast_visible_then_hidden", { S.waitTicks({ ticks = 20 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  h.scheduler:createTask("movement", { actor = "beast", sequence = { segment } }, instance, 100, nil)
  h.scheduler:step(101, nil)
  h.services.actors:hide("beast")
  h.scheduler:step(102, nil)
  Assert.deepEqual(calls, { "SEQ_SE_DP_DANSA" })

  local h2 = harness()
  h2.services.actors:add("beast", { fieldX = 0, fieldZ = 0, facing = "south", visible = false })
  local calls2 = {}
  h2.services.audio = {
    play = function(_, effectId)
      calls2[#calls2 + 1] = effectId
    end,
  }
  local resource2 = script("test.beast_hidden_then_visible", { S.waitTicks({ ticks = 20 }) })
  local instanceId2 = startForeground(h2, resource2, 200)
  local instance2 = assert(h2.scheduler:instance(instanceId2))
  h2.scheduler:createTask("movement", { actor = "beast", sequence = { segment } }, instance2, 200, nil)
  h2.scheduler:step(201, nil)
  h2.services.actors:show("beast")
  h2.scheduler:step(202, nil)
  Assert.deepEqual(calls2, { "SEQ_SE_DP_SUTYA2" })

  local h3 = harness()
  local opaque = {
    getPosition = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    getFacing = function()
      return "south"
    end,
    setFacing = function() end,
    beginScriptedAction = function() end,
    advanceScriptedAction = function() end,
    commitScriptedAction = function() end,
    cancelScriptedMovement = function() end,
    show = function() end,
    hide = function() end,
  }
  h3.services.actors = opaque --[[@as FakeActors]]
  local calls3 = {}
  h3.services.audio = {
    play = function(_, effectId)
      calls3[#calls3 + 1] = effectId
    end,
  }
  local resource3 = script("test.beast_opaque_visibility", { S.waitTicks({ ticks = 20 }) })
  local instanceId3 = startForeground(h3, resource3, 300)
  local instance3 = assert(h3.scheduler:instance(instanceId3))
  h3.scheduler:createTask("movement", { actor = "beast", sequence = { segment } }, instance3, 300, nil)
  h3.scheduler:step(301, nil)
  h3.scheduler:step(302, nil)
  Assert.equal(#calls3, 0, "without a visibility answer no cry may play")
  Assert.notNil(
    h3.services.events:eventFor("script.error", instanceId3),
    "an unanswerable visibility check must fault instead of defaulting to visible"
  )
end

T["cancelling a live trainer reveal removes only the emitted effect"] = function()
  local h = harness()
  h.services.actors:add("rival", { fieldX = 2, fieldZ = 5, facing = "south" })
  local live = { [41] = true }
  local removed = {}
  local ownerRemovals = {}
  ---@diagnostic disable-next-line: inject-field
  h.services.effects = {
    emit = function(_, request)
      Assert.equal(request.kind, "trainer_reveal")
      live[77] = true
      return 77
    end,
    remove = function(_, handle)
      removed[#removed + 1] = handle
      live[handle] = nil
    end,
    removeByOwner = function(_, ownerId, kind)
      ownerRemovals[#ownerRemovals + 1] = { ownerId = ownerId, kind = kind }
    end,
  }
  local resource = script("test.reveal_cancel", { S.waitTicks({ ticks = 500 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  h.scheduler:createTask(
    "movement",
    { actor = "rival", sequence = { { action = "reveal_trainer" } } },
    instance,
    100,
    nil
  )
  h.scheduler:step(101, nil)
  local envId = assert(h.scheduler:foregroundEnvironmentId())
  Assert.notNil(
    h.scheduler:activeMovementForActor(envId, "rival"),
    "the reveal task owns the actor after its first poll"
  )
  h.scheduler:cancelEnvironment(envId, "cancelled")
  Assert.deepEqual(removed, { 77 }, "cancellation removes exactly the emitted reveal handle")
  Assert.equal(#ownerRemovals, 0, "cancellation must not fall back to owner-wide removal")
  Assert.isTrue(live[41], "an unrelated effect survives another task's cancellation")
  Assert.isNil(h.services.events:eventFor("script.error", instanceId), "exact cleanup cancels without faulting")
end

T["failed reveal cleanup faults the owning script"] = function()
  local h = harness()
  h.services.actors:add("rival", { fieldX = 2, fieldZ = 5, facing = "south" })
  ---@diagnostic disable-next-line: inject-field
  h.services.effects = {
    emit = function(_)
      return 77
    end,
    remove = function(_)
      error("boom-remove-77")
    end,
  }
  local resource = script("test.reveal_cleanup_fault", { S.waitTicks({ ticks = 500 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  h.scheduler:createTask(
    "movement",
    { actor = "rival", sequence = { { action = "reveal_trainer" } } },
    instance,
    100,
    nil
  )
  h.scheduler:step(101, nil)
  local envId = assert(h.scheduler:foregroundEnvironmentId())
  h.scheduler:cancelEnvironment(envId, "cancelled")
  local fault = assert(
    h.services.events:eventFor("script.error", instanceId),
    "a cleanup failure must fault the owning script instead of cancelling quietly"
  )
  Assert.equal(fault.code, "SCRIPT_TASK_CALLBACK_FAULT")
end

-- A semantic farther jump displaces three cells, not one: the shared fake
-- actor and player doubles must model the same endpoint the calibrated
-- production runtime publishes.
T["farther jump advances three cells through the shared fake"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local instanceId = startForeground(h, script("test.farther_jump", { S.waitTicks({ ticks = 20 }) }), 100)
  local instance = assert(h.scheduler:instance(instanceId))
  h.scheduler:createTask("movement", {
    actor = "elm",
    sequence = { { action = "jump", direction = "east", distance = "farther", speed = "fast" } },
    blocking = true,
  }, instance, 100, nil)
  -- A fast farther jump runs 12 plan ticks: polls 101..112.
  for tick = 101, 100 + MovementCalibration.actionTicks({ action = "jump", distance = "farther", speed = "fast" }) do
    h.scheduler:step(tick, nil)
  end
  Assert.equal(h.services.actors.actors.elm.fieldX, 7, "a farther jump commits three cells east")
  Assert.equal(h.services.actors.actors.elm.fieldZ, 6, "a farther jump keeps its lane")

  local startX, startZ = h.services.player.fieldX, h.services.player.fieldZ
  h.services.player:beginScriptedAction({ action = "jump", direction = "east", distance = "farther", speed = "fast" })
  h.services.player:commitScriptedAction()
  Assert.equal(h.services.player.fieldX, startX + 3, "the fake player commits three cells east")
  Assert.equal(h.services.player.fieldZ, startZ, "the fake player keeps its lane")
end

return { tests = T }
