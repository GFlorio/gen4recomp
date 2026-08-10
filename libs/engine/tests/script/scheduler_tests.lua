-- Scheduler and core instance runtime tests.
-- They pin the source-derived execution model: run
-- to yield (not one node per tick), at most one run per context per tick,
-- tasks that never poll in their creation tick, completion recorded
-- separately from continuation, distinct `yield_tick` vs `wait_ticks(1)`
-- timelines, dynamic context-slot visitation, common child handoff, the
-- per-run node budget, cancellation and fault cleanup, and lock ownership.
-- Pure state/control scripts reproduce the source
-- run-to-yield and handoff timing without UI or actor dependencies.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
local ChildScriptTask = require("libs.engine.src.script.tasks.ChildScriptTask")
local FakeServices = require("tests.support.script.FakeServices")
local Diagnostics = require("libs.engine.src.script.Diagnostics")

local T = {}

---@class SchedulerHarness
---@field services FakeServices
---@field registry Registry
---@field composition Composition
---@field taskRegistry TaskRegistry
---@field scheduler Scheduler
---@field trace Diagnostics.TraceRecorder

---@param opts table|nil
---@return SchedulerHarness
local function harness(opts)
  opts = opts or {}
  local services = FakeServices.new(opts)
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("child_script", 1, ChildScriptTask)
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

---@param id string
---@param stepsOrSpec table[]|table steps array, or a full script spec (api added)
---@return table
local function script(id, stepsOrSpec)
  if type(stepsOrSpec) == "table" and stepsOrSpec.steps ~= nil then
    stepsOrSpec = stepsOrSpec
    stepsOrSpec.api = 1
    stepsOrSpec.id = id
    return S.script(stepsOrSpec)
  end
  return S.script({ api = 1, id = id, steps = stepsOrSpec })
end

-- Install a base script and start it as the foreground root at the given
-- tick; returns the instance id.
---@param h SchedulerHarness
---@param resource table
---@param tick integer
---@param trigger table|nil
---@return string
local function startForeground(h, resource, tick, trigger)
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, trigger, tick)
end

---@param h SchedulerHarness
---@param from integer
---@param to integer
---@param input table|nil
local function runTicks(h, from, to, input)
  for tick = from, to do
    h.scheduler:step(tick, input)
  end
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
end

-- 1. Several non-blocking nodes execute in one tick: SetVar; SetFlag; End.
T["same-tick chain"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.chain", {
      S.setVar({ variable = "VAR_SCENE", value = 1 }),
      S.setFlag({ flag = "FLAG_SCENE" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_SCENE"), 1)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_SCENE"))
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.status, "completed")
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
end

-- 2. yield_tick: successor executes exactly next tick.
T["yield_tick successor next tick"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.yield", {
      S.yieldTick(),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 0)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 1)
end

-- 3. waitTicks(1) timeline: create at T, first poll at T+1 completes, graph
-- continuation at T+2.
T["wait_ticks one timeline"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.wait1", {
      S.waitTicks({ ticks = 1 }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 0)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 0, "successful poll must not continue same tick")
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 1)
end

-- 4. waitTicks(3): T create, T+3 complete, T+4 continuation.
T["wait_ticks three timeline"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.wait3", {
      S.waitTicks({ ticks = 3 }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  for tick = 100, 102 do
    h.scheduler:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_A"), 0)
  h.scheduler:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 0)
  h.scheduler:step(104, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 1)
end

-- 5. yield_tick and waitTicks(1) are intentionally different.
T["yield_tick vs wait_ticks one"] = function()
  local h1 = harness()
  startForeground(
    h1,
    script("test.a", {
      S.yieldTick(),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  h1.scheduler:step(100, nil)
  h1.scheduler:step(101, nil)
  Assert.equal(h1.services.world:getVar("VAR_A"), 1)
  local h2 = harness()
  startForeground(
    h2,
    script("test.b", {
      S.waitTicks({ ticks = 1 }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  h2.scheduler:step(100, nil)
  h2.scheduler:step(101, nil)
  Assert.equal(h2.services.world:getVar("VAR_A"), 0)
  h2.scheduler:step(102, nil)
  Assert.equal(h2.services.world:getVar("VAR_A"), 1)
end

-- 6. A task never polls in its creation tick: no poll records before T+1.
T["no creation tick poll"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.poll", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local polled = {}
  for _, record in ipairs(h.trace:records()) do
    if record.kind == "task_polled" then
      polled[#polled + 1] = record.tick
    end
  end
  Assert.equal(#polled, 0, "no task may poll in its creation tick")
  h.scheduler:step(101, nil)
  local first = assert(h.trace:records()[#h.trace:records()])
  Assert.equal(first.kind, "task_polled")
  Assert.equal(first.tick, 101)
end

-- 7. A local call may return in the same tick.
T["local call returns same tick"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.call", {
      S.call({ target = "sub" }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
      S.label({ name = "sub" }),
      S.setVar({ variable = "VAR_SUB", value = 1 }),
      S.return_({}),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_SUB"), 1)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 8. Local call with args and a result value.
T["local call args and result"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.callres", {
      locals = { out = "integer" },
      params = { value = "integer" },
      steps = {
        S.setLocal({ name = "out", value = 0 }),
        S.call({ target = "double", args = { value = 21 }, result = S.local_("out") }),
        S.if_({
          condition = S.eq(S.local_("out"), 42),
          yes = { S.setFlag({ flag = "FLAG_OK" }), S.stop() },
          no = { S.setVar({ variable = "VAR_BAD", value = 1 }), S.stop() },
        }),
        S.label({ name = "double" }),
        S.setVar({ variable = "VAR_TMP", value = S.arg("value") }),
        S.addVar({ variable = "VAR_TMP", amount = S.var("VAR_TMP") }),
        S.return_({ value = S.var("VAR_TMP") }),
      },
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_OK"))
  Assert.equal(h.services.world:getVar("VAR_BAD"), 0)
end

-- 9. A subroutine that falls off its end behaves like `return`.
T["fall off end returns"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.falloff", {
      S.call({ target = "sub" }),
      S.setFlag({ flag = "FLAG_AFTER" }),
      S.stop(),
      S.label({ name = "sub" }),
      S.setVar({ variable = "VAR_SUB", value = 7 }),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_SUB"), 7)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_AFTER"))
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
end

-- 10. A callee that returns its own argument evaluates the value against
-- its own frame, not the caller's.
T["return evaluates the callee's own argument"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.retarg", {
      params = { value = "integer" },
      steps = {
        S.call({ target = "echo", args = { value = 42 } }),
        S.setVar({ variable = "VAR_AFTER", value = S.var("VAR_RESULT") }),
        S.stop(),
        S.label({ name = "echo" }),
        S.setVar({ variable = "VAR_RESULT", value = S.arg("value") }),
        S.return_({ value = S.arg("value") }),
      },
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    42,
    "return_ evaluates the callee's argument before popping its frame"
  )
end

-- 11. A new interaction resolves and runs in the trigger tick; its tasks
-- still first poll on the next tick.
T["interaction runs in trigger tick"] = function()
  local h = harness()
  local resource = script("new_bark.lab_sign", {
    S.setVar({ variable = "VAR_SCENE", value = 1 }),
    S.waitTicks({ ticks = 2 }),
    S.stop(),
  })
  h.registry:installBase(resource.id, resource, "generated")
  local trigger = { kind = "object", mapId = 58, scriptId = resource.id, selfActor = "doctor" }
  h.services.foreground = {
    resolve = function(input)
      if input and input.pressedAction then
        return { trigger = trigger, composed = h.composition:effective(resource.id) }
      end
      return nil
    end,
  }
  h.scheduler:step(200, { pressedAction = true })
  Assert.equal(
    h.services.world:getVar("VAR_SCENE"),
    1,
    "a newly created interaction may execute during its trigger tick"
  )
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.trigger.kind, "object")
  h.scheduler:step(201, {})
  Assert.equal(h.services.world:getVar("VAR_SCENE"), 1)
  h.scheduler:step(202, {})
  h.scheduler:step(203, {})
  Assert.equal(instance.status, "completed")
end

-- 11. No new interaction resolves while a foreground root owns the field.
T["interaction blocked while foreground active"] = function()
  local h = harness()
  local resource = script("new_bark.lab_sign", {
    S.waitTicks({ ticks = 5 }),
    S.stop(),
  })
  h.registry:installBase(resource.id, resource, "generated")
  local resolves = 0
  h.services.foreground = {
    resolve = function(input)
      if input and input.pressedAction then
        resolves = resolves + 1
        return {
          trigger = { kind = "object", scriptId = resource.id },
          composed = h.composition:effective(resource.id),
        }
      end
      return nil
    end,
  }
  h.scheduler:step(200, { pressedAction = true })
  Assert.equal(resolves, 1)
  h.scheduler:step(201, { pressedAction = true })
  Assert.equal(resolves, 1, "a foreground root owns the field")
end

-- 12. Context runs at most once per tick: one run per tick,
-- never two.
T["at most one run per tick"] = function()
  local h = harness()
  local runTicks = {}
  startForeground(
    h,
    script("test.once", {
      S.yieldTick(),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  for _, record in ipairs(h.trace:records()) do
    if record.kind == "context_run" then
      runTicks[#runTicks + 1] = record.tick
    end
  end
  Assert.deepEqual(runTicks, { 100, 101 })
end

-- 13. Common child: stable slot ordering, caller blocked, signal handoff,
-- parent resumes one tick after the successful poll.
T["common child handoff"] = function()
  local h = harness()
  local common = script("common.greeting", {
    S.setVar({ variable = "VAR_CHILD", value = 1 }),
    { op = "signal_caller" },
    S.stop(),
  })
  h.registry:installBase(common.id, common, "generated")
  local root = script("test.std", {
    S.callCommon({ target = "common.greeting" }),
    S.setVar({ variable = "VAR_PARENT", value = 1 }),
    S.stop(),
  })
  startForeground(h, root, 100)
  local childInstanceId = nil
  h.services.foreground = nil
  h.scheduler:step(100, nil)
  -- The child was created in slot 1 during the caller's run and, because its
  -- slot had not yet been visited, ran in the same tick.
  Assert.equal(h.services.world:getVar("VAR_CHILD"), 1)
  Assert.equal(h.services.world:getVar("VAR_PARENT"), 0)
  local instances = h.scheduler:instances()
  Assert.equal(#instances, 2)
  local caller = assert(h.scheduler:instances()[1])
  local child
  for _, instance in ipairs(instances) do
    if instance.contextSlot == 1 then
      child = instance
    end
  end
  childInstanceId = assert(child).instanceId
  Assert.equal(caller.status, "blocked")
  -- The child signalled and terminated: its task completes at T+1's poll and
  -- the parent resumes at T+2.
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_PARENT"), 0)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_PARENT"), 1)
  Assert.equal(caller.status, "completed")
end

-- 14. Context-slot exhaustion faults with SCRIPT_CONTEXT_SLOTS_EXHAUSTED.
T["context slot exhaustion"] = function()
  local h = harness()
  local common = script("common.a", {
    S.callCommon({ target = "common.b" }),
    { op = "signal_caller" },
    S.stop(),
  })
  local commonB = script("common.b", {
    S.callCommon({ target = "common.c" }),
    { op = "signal_caller" },
    S.stop(),
  })
  local commonC = script("common.c", {
    { op = "signal_caller" },
    S.stop(),
  })
  h.registry:installBase(common.id, common, "generated")
  h.registry:installBase(commonB.id, commonB, "generated")
  h.registry:installBase(commonC.id, commonC, "generated")
  startForeground(
    h,
    script("test.slots", {
      S.callCommon({ target = "common.a" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  local faulted = false
  for _, instance in ipairs(h.scheduler:instances()) do
    if instance.status == "faulted" and instance.endReason == "SCRIPT_CONTEXT_SLOTS_EXHAUSTED" then
      faulted = true
    end
  end
  Assert.isTrue(faulted)
end

-- 15. Infinite non-blocking loop faults with SCRIPT_STEP_BUDGET_EXCEEDED
-- rather than yielding.
T["step budget fault"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.loop", {
      S.label({ name = "loop" }),
      S.goto_({ target = "loop" }),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.status, "faulted")
  Assert.equal(instance.endReason, "SCRIPT_STEP_BUDGET_EXCEEDED")
  local errorEvent = nil
  for _, record in ipairs(h.services.events.records) do
    if record.name == "script.error" then
      errorEvent = record.payload
    end
  end
  ---@cast errorEvent table
  Assert.notNil(errorEvent)
  Assert.equal(errorEvent.code, "SCRIPT_STEP_BUDGET_EXCEEDED")
end

-- 16. The budget limit is precise: exactly N non-blocking nodes complete,
-- the (N+1)th faults.
T["budget boundary"] = function()
  local function budgetScript(count)
    local steps = {}
    for i = 1, count do
      steps[#steps + 1] = S.noop()
    end
    steps[#steps + 1] = S.setVar({ variable = "VAR_DONE", value = 1 })
    steps[#steps + 1] = S.stop()
    return script("test.budget" .. count, steps)
  end
  local h = harness()
  h.scheduler:setMaxNodes(8)
  startForeground(h, budgetScript(7), 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_DONE"), 1, "exactly N continues complete within the budget")
  local h2 = harness()
  h2.scheduler:setMaxNodes(8)
  startForeground(h2, budgetScript(8), 200)
  h2.scheduler:step(200, nil)
  local instance = assert(h2.scheduler:instance("script-00000001"))
  Assert.equal(instance.status, "faulted")
  Assert.equal(instance.endReason, "SCRIPT_STEP_BUDGET_EXCEEDED")
end

-- 17. Locks: owner-counted, released on completion, and strict release.
T["lock ownership and release"] = function()
  local h = harness()
  local instanceId = startForeground(
    h,
    script("test.locks", {
      S.lockPlayer(),
      S.lockPlayer(),
      S.releasePlayer(),
      S.setFlag({ flag = "FLAG_MID" }),
      S.releasePlayer(),
      S.stop(),
    }),
    100
  )
  local env = assert(h.scheduler:environments()[1])
  h.scheduler:step(100, nil)
  Assert.equal(env:lockCount("player"), 0)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_MID"))
  Assert.equal(assert(h.scheduler:instance(instanceId)).status, "completed")
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
end

T["release unowned lock errors"] = function()
  local h = harness()
  local instanceId = startForeground(
    h,
    script("test.badrelease", {
      S.releasePlayer(),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local instance = assert(h.scheduler:instance(instanceId))
  Assert.equal(instance.status, "faulted")
  Assert.equal(instance.endReason, "SCRIPT_LOCK_NOT_OWNED")
end

-- 18. Ending an instance releases its locks.
T["completion releases locks"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.locks2", {
      S.lockAll(),
      S.setFlag({ flag = "FLAG_LOCKED" }),
      S.releaseAll(),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_LOCKED"))
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
end

-- 19. Cancellation: tasks, slots, signals, and locks all cleaned up, and
-- script.ended reports completed = false.
T["cancellation cleanup"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.cancel", {
      S.lockPlayer(),
      S.waitTicks({ ticks = 10 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local env = assert(h.scheduler:environments()[1])
  local instance = assert(h.scheduler:instances()[1])
  h.scheduler:cancelEnvironment(env.environmentId, "map transition")
  Assert.equal(instance.status, "cancelled")
  Assert.equal(instance.endReason, "map transition")
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
  Assert.equal(#h.scheduler:tasks(), 0)
  local ended = nil
  for _, record in ipairs(h.services.events.records) do
    if record.name == "script.ended" then
      ended = record.payload
    end
  end
  ---@cast ended table
  Assert.notNil(ended)
  Assert.isFalse(ended.completed)
  Assert.equal(ended.reason, "map transition")
end

-- 20. Fault cleanup releases locks and ownership (definition of done: errors
-- release locks and task ownership).
T["fault cleanup"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.fault", {
      S.lockAll(),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.releaseAll(),
      S.releasePlayer(),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  local env = h.scheduler:environments()[1]
  Assert.isNil(env, "environment torn down after root fault")
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
end

-- 21. Dynamic slot visitation: a child created in a later unvisited slot runs
-- in the caller's tick.
T["child runs in caller tick when slot unvisited"] = function()
  local h = harness()
  local common = script("common.quick", {
    S.setVar({ variable = "VAR_CHILD", value = 9 }),
    { op = "signal_caller" },
    S.stop(),
  })
  h.registry:installBase(common.id, common, "generated")
  startForeground(
    h,
    script("test.dyn", {
      S.callCommon({ target = "common.quick" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_CHILD"), 9)
end

-- 22. External call through composition: a script calling another registered
-- script id.
T["external call same tick"] = function()
  local h = harness()
  local callee = script("scripts.helper", {
    S.setFlag({ flag = "FLAG_HELPER" }),
    S.return_({}),
  })
  h.registry:installBase(callee.id, callee, "generated")
  startForeground(
    h,
    script("test.extcall", {
      S.call({ target = "scripts.helper" }),
      S.setFlag({ flag = "FLAG_AFTER" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_HELPER"))
  Assert.isTrue(h.services.world:isFlagSet("FLAG_AFTER"))
end

-- 23. Missing call target faults with SCRIPT_CALL_TARGET_MISSING.
T["missing call target"] = function()
  local h = harness()
  local instanceId = startForeground(
    h,
    script("test.missing", {
      S.call({ target = "scripts.nowhere" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.scheduler:instance(instanceId)).status, "faulted")
  Assert.equal(assert(h.scheduler:instance(instanceId)).endReason, "SCRIPT_CALL_TARGET_MISSING")
end

-- 24. Wrapper composition: a before script that ends its linear tail falls
-- through to the base (the example-mod preface behavior);
-- ownership flows through frames.
T["wrapper chain fall through"] = function()
  local h = harness()
  local base = script("new_bark.lab_sign", {
    S.setVar({ variable = "VAR_BASE", value = 1 }),
    S.stop(),
  })
  h.registry:installBase(base.id, base, "generated")
  local preface = script("example.preface", {
    S.setVar({ variable = "VAR_PRE", value = 1 }),
  })
  h.registry:before(base.id, preface, { modId = "example.mod" }, { priority = 0 })
  startForeground(h, base, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_PRE"), 1)
  Assert.equal(h.services.world:getVar("VAR_BASE"), 1)
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.status, "completed")
end

-- 25. A wrapper `next` mid-script jumps into the next contribution.
T["wrapper explicit next"] = function()
  local h = harness()
  local base = script("new_bark.lab_sign", {
    S.setVar({ variable = "VAR_BASE", value = 1 }),
    S.stop(),
  })
  h.registry:installBase(base.id, base, "generated")
  local preface = script("example.preface", {
    S.setVar({ variable = "VAR_PRE", value = 1 }),
    S.next(),
    S.setVar({ variable = "VAR_SKIPPED", value = 1 }),
  })
  h.registry:before(base.id, preface, { modId = "example.mod" }, { priority = 0 })
  startForeground(h, base, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_PRE"), 1)
  Assert.equal(h.services.world:getVar("VAR_BASE"), 1)
  Assert.equal(h.services.world:getVar("VAR_SKIPPED"), 0, "nodes after next are unreachable on the path")
end

-- 26. A wrapper ending with `stop` consumes the original behavior.
T["wrapper consumes with stop"] = function()
  local h = harness()
  local base = script("new_bark.lab_sign", {
    S.setVar({ variable = "VAR_BASE", value = 1 }),
    S.stop(),
  })
  h.registry:installBase(base.id, base, "generated")
  local preface = script("example.preface", {
    S.setVar({ variable = "VAR_PRE", value = 1 }),
    S.stop(),
  })
  h.registry:before(base.id, preface, { modId = "example.mod" }, { priority = 0 })
  startForeground(h, base, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_PRE"), 1)
  Assert.equal(h.services.world:getVar("VAR_BASE"), 0)
end

-- 27. signal_caller in the root context is invalid.
T["signal_caller in root faults"] = function()
  local h = harness()
  local instanceId = startForeground(
    h,
    script("test.signal", {
      { op = "signal_caller" },
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local instance = assert(h.scheduler:instance(instanceId))
  Assert.equal(instance.status, "faulted")
  Assert.equal(instance.endReason, "SCRIPT_CALLER_SIGNAL_INVALID")
end

-- 28. Background scripts cannot lock the player, warp, or open dialogue
--; state/control ops are legal.
T["background restrictions"] = function()
  local h = harness()
  local bg = script("map.background", {
    S.setVar({ variable = "VAR_BG", value = 1 }),
    S.lockPlayer(),
    S.stop(),
  })
  h.registry:installBase(bg.id, bg, "generated")
  local composed = assert(h.composition:effective(bg.id))
  local instanceId = h.scheduler:createBackground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_BG"), 1)
  local instance = assert(h.scheduler:instance(instanceId))
  Assert.equal(instance.status, "faulted")
  Assert.equal(instance.endReason, "SCRIPT_BACKGROUND_FORBIDDEN")
end

-- 29. Actor locks are exclusive per actor.
T["actor lock exclusivity"] = function()
  local h = harness()
  local common = script("common.a", {
    S.lockActor({ actor = "elm" }),
    { op = "signal_caller" },
    S.stop(),
  })
  h.registry:installBase(common.id, common, "generated")
  startForeground(
    h,
    script("test.actorlock", {
      S.callCommon({ target = "common.a" }),
      S.lockActor({ actor = "elm" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  -- The parent's lock attempt runs at 101+; the child already owns elm.
  local instance
  for _, i in ipairs(h.scheduler:instances()) do
    if i.contextSlot == 0 then
      instance = i
    end
  end
  Assert.isFalse(assert(instance).status == "completed")
end

-- 30. Deterministic traces: context runs, yields, blocks, task polls, and
-- completions are all recorded in order.
T["deterministic traces"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.trace", {
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.waitTicks({ ticks = 1 }),
      S.setVar({ variable = "VAR_B", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  local kinds = {}
  for _, record in ipairs(h.trace:records()) do
    kinds[#kinds + 1] = record.kind
  end
  Assert.deepEqual(kinds, {
    "environment_created",
    "context_run",
    "task_created",
    "context_blocked",
    "task_polled",
    "resume_promoted",
    "context_run",
    "context_completed",
    "environment_torn_down",
  })
  local runRecord = h.trace:records()[2]
  Assert.equal(runRecord.tick, 100)
  local polled = h.trace:records()[5]
  Assert.equal(polled.tick, 101)
  Assert.isTrue(polled.complete)
end

-- 31. Actor-facing operations resolve through trigger context and apply to
-- the actor world.
T["actor operations"] = function()
  local h = harness()
  h.services.actors:add("obj_T20R0101_doctor", { fieldX = 4, fieldZ = 5, facing = "north" })
  h.services.actors:add("player", { fieldX = 10, fieldZ = 10, facing = "south" })
  startForeground(
    h,
    script("test.actors", {
      locals = { px = "integer", pz = "integer", ex = "integer", ez = "integer", pf = "string" },
      steps = {
        S.facePlayer({ actor = "self" }),
        S.setObjectFacing({ actor = "obj_T20R0101_doctor", direction = "east" }),
        S.setObjectPosition({ actor = "obj_T20R0101_doctor", fieldX = 9, fieldZ = 8 }),
        S.hideObject({ actor = "obj_T20R0101_doctor" }),
        S.showObject({ actor = "obj_T20R0101_doctor" }),
        S.getPlayerCoords({ x = S.local_("px"), z = S.local_("pz") }),
        S.getObjectCoords({ actor = "obj_T20R0101_doctor", x = S.local_("ex"), z = S.local_("ez") }),
        S.getPlayerFacing({ result = S.local_("pf") }),
        S.waitTicks({ ticks = 1 }),
        S.stop(),
      },
    }),
    100,
    { kind = "object", selfActor = "obj_T20R0101_doctor" }
  )
  h.scheduler:step(100, nil)
  local doctor = h.services.actors.actors["obj_T20R0101_doctor"]
  Assert.equal(doctor.facing, "east", "setObjectFacing runs after facePlayer")
  Assert.equal(doctor.fieldX, 9)
  Assert.equal(doctor.fieldZ, 8)
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.locals.px, 10)
  Assert.equal(instance.locals.pz, 10)
  Assert.equal(instance.locals.ex, 9)
  Assert.equal(instance.locals.ez, 8)
  Assert.equal(instance.locals.pf, "south")
end

-- 32. Missing actors are attributed errors.
T["missing actor fault"] = function()
  local h = harness()
  local instanceId = startForeground(
    h,
    script("test.missingactor", {
      S.face({ actor = "nowhere", direction = "north" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local instance = assert(h.scheduler:instance(instanceId))
  Assert.equal(instance.status, "faulted")
  Assert.equal(instance.endReason, "SCRIPT_ACTOR_NOT_FOUND")
end

-- 33. Conditions: compare, flag, not/all/any, truthy.
T["condition evaluation"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.conds", {
      S.if_({
        condition = S.all({
          S.eq(S.var("VAR_A"), 0),
          S.not_(S.flag("FLAG_A")),
        }),
        yes = { S.setFlag({ flag = "FLAG_BRANCH" }), S.stop() },
        no = { S.setVar({ variable = "VAR_BAD", value = 1 }), S.stop() },
      }),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_BRANCH"))
  Assert.equal(h.services.world:getVar("VAR_BAD"), 0)
end

-- 34. Low-level compare state: compare then gotoCompared.
T["compare state fallback"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.compare", {
      S.compare({ left = 3, right = 3 }),
      S.gotoCompared({ operator = "eq", target = "match" }),
      S.setVar({ variable = "VAR_BAD", value = 1 }),
      S.stop(),
      S.label({ name = "match" }),
      S.setFlag({ flag = "FLAG_MATCH" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_MATCH"))
  Assert.equal(h.services.world:getVar("VAR_BAD"), 0)
end

-- 35. random writes through the deterministic RNG.
T["random uses script rng"] = function()
  local h = harness()
  h.services:withRng(1)
  startForeground(
    h,
    script("test.rng", {
      locals = { roll = "integer" },
      steps = {
        S.random({ maxExclusive = 100, result = S.local_("roll") }),
        S.waitTicks({ ticks = 1 }),
        S.stop(),
      },
    }),
    100
  )
  h.scheduler:step(100, nil)
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.locals.roll, 71)
  local h2 = harness()
  h2.services:withRng(1)
  startForeground(
    h2,
    script("test.rng", {
      locals = { roll = "integer" },
      steps = {
        S.random({ maxExclusive = 100, result = S.local_("roll") }),
        S.waitTicks({ ticks = 1 }),
        S.stop(),
      },
    }),
    100
  )
  h2.scheduler:step(100, nil)
  Assert.equal(assert(h2.scheduler:instances()[1]).locals.roll, 71)
end

-- --- Cross-script references ( rows 22/26/28/29) ------------
-- Shared script tails are same-context jumps resolved through the
-- composition registry at runtime, mirroring the raw-Lua escape hatch.

-- 3x. goto_script enters another script's label in the same tick; the
-- tail's End completes the instance.
T["goto_script enters another script's label"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.label({ name = "_0050" }),
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.stop(),
    }),
    "generated"
  )
  startForeground(
    h,
    script("test.jumper", {
      S.gotoScript({ script = "test.tail", label = "_0050" }),
      S.setVar({ variable = "VAR_NEVER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_TAIL"))
  Assert.equal(h.services.world:getVar("VAR_NEVER"), 0, "the jump must not fall through to the caller's next node")
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.status, "completed")
end

-- 3y. goto_script without a label jumps to the composed target's entry.
T["goto_script entry jump"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.stop(),
    }),
    "generated"
  )
  startForeground(
    h,
    script("test.jumper", {
      S.gotoScript({ script = "test.tail" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_TAIL"))
end

-- 3z. A cross-script call with a label returns to the caller's continuation
-- in the same tick (local-call semantics across scripts).
T["cross-script call with label returns to the caller"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.label({ name = "_0050" }),
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.return_({}),
      S.setVar({ variable = "VAR_NEVER", value = 1 }),
      S.stop(),
    }),
    "generated"
  )
  startForeground(
    h,
    script("test.caller", {
      S.call({ target = "test.tail", label = "_0050" }),
      S.setVar({ variable = "VAR_AFTER", value = 7 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_TAIL"))
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    7,
    "the caller must continue in the same tick after the callee returns"
  )
  Assert.equal(h.services.world:getVar("VAR_NEVER"), 0)
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.status, "completed")
end

-- 3w. A conditional cross-script jump (the structured if wrap) selects the
-- branch in the same tick.
T["conditional cross-script jump"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.label({ name = "_0050" }),
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.stop(),
    }),
    "generated"
  )
  startForeground(
    h,
    script("test.cond", {
      S.setVar({ variable = "VAR_SCENE", value = 2 }),
      S.if_({
        condition = S.eq(S.var("VAR_SCENE"), 1),
        yes = { S.gotoScript({ script = "test.tail", label = "_0050" }) },
        no = { S.setVar({ variable = "VAR_NO", value = 1 }) },
      }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isFalse(h.services.world:isFlagSet("FLAG_TAIL"))
  Assert.equal(h.services.world:getVar("VAR_NO"), 1)

  startForeground(
    h,
    script("test.cond2", {
      S.setVar({ variable = "VAR_SCENE", value = 1 }),
      S.if_({
        condition = S.eq(S.var("VAR_SCENE"), 1),
        yes = { S.gotoScript({ script = "test.tail", label = "_0050" }) },
        no = { S.setVar({ variable = "VAR_NO2", value = 1 }) },
      }),
      S.stop(),
    }),
    200
  )
  h.scheduler:step(200, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_TAIL"))
end

-- 3v. Missing cross-script targets and labels are attributed faults.
T["cross-script reference errors are attributed"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.stop(),
    }),
    "generated"
  )
  local badTarget = startForeground(
    h,
    script("test.badtarget", {
      S.gotoScript({ script = "test.missing" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.scheduler:instance(badTarget)).endReason, "SCRIPT_CALL_TARGET_MISSING")

  local badLabel = startForeground(
    h,
    script("test.badlabel", {
      S.gotoScript({ script = "test.tail", label = "_nope" }),
      S.stop(),
    }),
    200
  )
  h.scheduler:step(200, nil)
  Assert.equal(assert(h.scheduler:instance(badLabel)).endReason, "SCRIPT_LABEL_MISSING")
end

-- 3u. A mod that replaces the target script redirects the jump: the
-- reference is resolved through the composition registry at execution time.
T["goto_script resolves the composed target"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.stop(),
    }),
    "generated"
  )
  local replacement = script("test.tail", {
    S.setVar({ variable = "VAR_REPLACED", value = 9 }),
    S.stop(),
  })
  h.registry:override("test.tail", replacement, { modId = "mod.a" }, {})
  startForeground(
    h,
    script("test.jumper", {
      S.gotoScript({ script = "test.tail" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_REPLACED"), 9)
  Assert.isFalse(h.services.world:isFlagSet("FLAG_TAIL"))
end

-- 3t. Cross-script compare-state branches: the low-level goto_compared/
-- call_compared forms consume the compare state at runtime and resolve the
-- composed target like the source engine.
T["cross-script compare-state branch"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.label({ name = "_0050" }),
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.stop(),
    }),
    "generated"
  )
  startForeground(
    h,
    script("test.cmpfalse", {
      S.setVar({ variable = "VAR_A", value = 0 }),
      S.compare({ left = S.var("VAR_A"), right = 1 }),
      S.gotoCompared({ operator = "eq", script = "test.tail", label = "_0050" }),
      S.setVar({ variable = "VAR_NEVER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.isFalse(h.services.world:isFlagSet("FLAG_TAIL"))
  Assert.equal(h.services.world:getVar("VAR_NEVER"), 1, "a false compare state must not jump")

  startForeground(
    h,
    script("test.cmptrue", {
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.compare({ left = S.var("VAR_A"), right = 1 }),
      S.gotoCompared({ operator = "eq", script = "test.tail", label = "_0050" }),
      S.setVar({ variable = "VAR_NEVER", value = 2 }),
      S.stop(),
    }),
    200
  )
  h.scheduler:step(200, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_TAIL"))
  Assert.equal(h.services.world:getVar("VAR_NEVER"), 1, "the taken branch must not fall through")
  Assert.equal(assert(h.scheduler:instances()[1]).status, "completed")
end

-- 3s. An observable countdown variable is mirrored into the world store
-- exactly like the source engine: the frame count at creation, one
-- decrement per poll, zero on completion.
T["countdown mirror writes and decrements the variable"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.mirror", {
      S.waitTicks({ ticks = 3, countdownVariable = "VAR_COUNTDOWN" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 3, "the frame count is written at creation")
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 2)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 1)
  h.scheduler:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 0, "the countdown reaches zero on the completing poll")
end

-- 3r. Map-object index and camera-target actor references resolve against
-- the current map through the actor adapter (the pinned HGSS object-id
-- path); a missing mapping is an attributed error.
T["map index and camera target actors"] = function()
  local h = harness()
  h.services.actors:add("obj_bench", { numericId = 2, fieldX = 7, fieldZ = 8 })
  h.services.actors:add("obj_cam", {})
  h.services.actors.mapIndexes = { [2] = "obj_bench" }
  h.services.actors.cameraTarget = "obj_cam"
  startForeground(
    h,
    script("test.mapindex", {
      S.getObjectCoords({ actor = S.actorIndex(2), x = S.var("VAR_X"), z = S.var("VAR_Z") }),
      S.lockActor({ actor = S.cameraTarget() }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_X"), 7, "the map index resolves to the current map's object")
  Assert.equal(h.services.world:getVar("VAR_Z"), 8)
  local instance = assert(h.scheduler:instances()[1])
  Assert.equal(instance.status, "completed")

  local bad = startForeground(
    h,
    script("test.mapmissing", {
      S.getObjectCoords({ actor = S.actorIndex(99), x = S.var("VAR_X"), z = S.var("VAR_Z") }),
      S.stop(),
    }),
    200
  )
  h.scheduler:step(200, nil)
  Assert.equal(assert(h.scheduler:instance(bad)).endReason, "SCRIPT_ACTOR_NOT_FOUND")
end

-- 3u. The countdown variable is the authoritative counter (source
-- RunPauseTimer semantics): a later write to it is observed and decremented,
-- so a mid-wait overwrite shortens the wait exactly like the source engine.
T["countdown variable write shortens the wait"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.shorten", {
      S.waitTicks({ ticks = 10, countdownVariable = "VAR_COUNTDOWN" }),
      S.setVar({ variable = "VAR_DONE", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 10)
  h.services.world:setVar("VAR_COUNTDOWN", 2)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 1)
  Assert.equal(h.services.world:getVar("VAR_DONE"), 0)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 0)
  h.scheduler:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_DONE"), 1, "the wait completed after the overwritten countdown ran out")
end

return T
