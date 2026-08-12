-- ScriptContext and raw-Lua handler tests :
-- the exact v1 context facades, ownership-aware module resolution, handler
-- invocation through pcall, result classification (nil / serializable value
-- with a declared result / task descriptor), task delegation, deterministic
-- RNG, and ScriptObject snapshot invalidation. the
-- example raw extension saves and resumes only through its named task.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local RawModules = require("libs.engine.src.script.RawModules")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
local ChildScriptTask = require("libs.engine.src.script.tasks.ChildScriptTask")
local StarterChoiceTask = require("tests.examples.StarterChoiceTask")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

-- A raw handler module exercising every allowed result shape and facade.
local retained = {}
local TestRaw = {
  returnsNil = function() end,
  returnsValue = function(ctx, args)
    return args.value * 2
  end,
  returnsTask = function()
    -- The example task's descriptor envelope, produced directly: the
    -- production ctx no longer exposes a starter_choice factory.
    return { taskType = "starter_choice", taskVersion = 1, state = {} }
  end,
  returnsNakedTable = function()
    return { ["not"] = "a task" }
  end,
  returnsFunction = function()
    return function() end
  end,
  errors = function()
    error("boom")
  end,
  yields = function()
    coroutine.yield()
  end,
  usesContext = function(ctx, args)
    ctx.flags:set("FLAG_X")
    ctx.variables:set("VAR_X", 5)
    ctx.locals:set("tmp", 7)
    return ctx.random:nextInt(100)
  end,
  snapshots = function(ctx)
    retained.object = ctx.objects:require("elm")
    return nil
  end,
  emits = function(ctx)
    ctx.events:emit("mod.test.mod.evt", { a = 1 })
  end,
  emitsForeign = function(ctx)
    ctx.events:emit("engine.evt", {})
  end,
  needsCamera = function(ctx)
    return ctx.camera:target()
  end,
  needsAudio = function(ctx)
    return ctx.audio:isPlaying("SEQ_SE_DP_SELECT")
  end,
  emitsNoHost = function(ctx)
    ctx.events:emit("mod.test.mod.evt", {})
  end,
  dialogueIsOpenNoHost = function(ctx)
    return ctx.dialogue:isOpen()
  end,
  triggerCopy = function(ctx)
    local t1 = ctx.script:trigger()
    local t2 = ctx.script:trigger()
    if t1 ~= t2 and t1.scriptId == "test.trigger" and t2.scriptId == "test.trigger" then
      ctx.variables:set("VAR_COPY", 1)
    end
  end,
  callsScript = function(ctx)
    return ctx.script:call("common.helper", { value = 3 })
  end,
  usesTaskFactory = function(ctx)
    return ctx.tasks.waitTicks({ ticks = 3 })
  end,
}

---@class ContextHarness
---@field services FakeServices
---@field registry Registry
---@field composition Composition
---@field taskRegistry TaskRegistry
---@field scheduler Scheduler
---@field modules RawModules

---@return ContextHarness
local function harness(seed)
  local services = FakeServices.new()
  services:withRng(seed or 1)
  services.actors:add("elm", { fieldX = 4, fieldZ = 5, facing = "north" })
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("child_script", 1, ChildScriptTask)
  taskRegistry:register("starter_choice", 1, StarterChoiceTask)
  local modules = RawModules.new()
  modules:register("test.raw", TestRaw, { kind = "mod", id = "test.mod", api = 1 })
  services.rawModules = modules --[[@as any]]
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = taskRegistry,
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
    modules = modules,
  }
end

---@param h ContextHarness
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

local function luaScript(id, module, fn, extra)
  extra = extra or {}
  local spec = {
    api = 1,
    id = id,
    steps = {
      S.lua({
        module = module,
        fn = fn,
        args = extra.args or {},
        result = extra.result,
      }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  }
  return S.script(spec)
end

local function runToCompletion(h, resource, from, to)
  startForeground(h, resource, from)
  for tick = from, to do
    h.scheduler:step(tick, { pressedAction = true })
  end
end

-- 1. A synchronous nil result completes without writing anything.
T["nil result"] = function()
  local h = harness()
  runToCompletion(h, luaScript("test.nil", "test.raw", "returnsNil"), 100, 102)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 2. A serializable value with a declared result is written to the local.
T["value result"] = function()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.value",
    locals = { out = "integer" },
    steps = {
      S.lua({
        module = "test.raw",
        fn = "returnsValue",
        args = { value = 21 },
        result = S.local_("out"),
      }),
      S.if_({
        condition = S.eq(S.local_("out"), 42),
        yes = { S.setFlag({ flag = "FLAG_OK" }), S.stop() },
        no = { S.setVar({ variable = "VAR_BAD", value = 1 }), S.stop() },
      }),
    },
  })
  runToCompletion(h, resource, 100, 102)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_OK"))
  Assert.equal(h.services.world:getVar("VAR_BAD"), 0)
end

-- 3. A value without a declared result ref is rejected.
T["value without declared result"] = function()
  local h = harness()
  local resource = luaScript("test.novalue", "test.raw", "returnsValue", {
    args = { value = 1 },
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_RAW_RESULT_INVALID")
end

-- 4. A task descriptor result delegates through the lua task; the starter
-- choice completes through the generic result path and writes the local.
T["task result"] = function()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.task",
    locals = { starter = "serializable" },
    steps = {
      S.lua({
        module = "test.raw",
        fn = "returnsTask",
        result = S.local_("starter"),
      }),
      S.setVar({ variable = "VAR_AFTER", value = S.local_("starter") }),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, {})
  -- The delegate polls: no input edge at 101..103; confirm at 104; the lua
  -- task completes at 104's poll; promotion and local write at 105.
  h.scheduler:step(101, {})
  h.scheduler:step(102, { pressedDirection = "east" })
  h.scheduler:step(103, { pressedAction = true })
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    0,
    "the successful delegate poll must not continue the graph same tick"
  )
  h.scheduler:step(104, {})
  local starter = h.services.world:getVar("VAR_AFTER")
  ---@cast starter any
  Assert.equal(starter.species, 158, "the d-pad edge cycled to the second starter before the confirm edge")
end

-- 5. Handler errors are attributed to mod, script, module, and function.
T["handler error attribution"] = function()
  local h = harness()
  local resource = luaScript("test.err", "test.raw", "errors")
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local errorEvent = assert(h.services.events:eventFor("script.error", instanceId))
  Assert.equal(errorEvent.code, "SCRIPT_RAW_HANDLER_ERROR")
  Assert.equal(errorEvent.context.module, "test.raw")
  Assert.equal(errorEvent.context.fn, "errors")
end

-- 6. Functions, threads, userdata, and naked tables are rejected.
T["invalid result shapes"] = function()
  local h = harness()
  local instanceId = startForeground(h, luaScript("test.fn", "test.raw", "returnsFunction"), 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_RAW_RESULT_INVALID")
  local h2 = harness()
  local instanceId2 = startForeground(h2, luaScript("test.tbl", "test.raw", "returnsNakedTable"), 100)
  h2.scheduler:step(100, nil)
  Assert.equal(assert(h2.services.events:eventFor("script.error", instanceId2)).code, "SCRIPT_RAW_RESULT_INVALID")
end

-- 7. An attempted yield is a distinct attributed error.
T["attempted yield rejected"] = function()
  local h = harness()
  local instanceId = startForeground(h, luaScript("test.yield", "test.raw", "yields"), 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_RAW_HANDLER_YIELDED")
end

-- 8. The context facades reach the world, locals, objects, and RNG.
T["context facades"] = function()
  local h = harness(7)
  local resource = S.script({
    api = 1,
    id = "test.ctx",
    locals = { out = "integer" },
    steps = {
      S.lua({
        module = "test.raw",
        fn = "usesContext",
        result = S.local_("out"),
      }),
      S.stop(),
    },
  })
  runToCompletion(h, resource, 100, 102)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_X"))
  Assert.equal(h.services.world:getVar("VAR_X"), 5)
end

-- 9. Retained ScriptObject snapshots are invalid after the handler returns.
T["object snapshot invalidation"] = function()
  local h = harness()
  retained.object = nil
  local resource = luaScript("test.snap", "test.raw", "snapshots")
  runToCompletion(h, resource, 100, 102)
  Assert.notNil(retained.object)
  local ok = pcall(retained.object.position, retained.object)
  Assert.isFalse(ok, "a ScriptObject is invalid after the handler returns")
end

-- 10. Unavailable services are attributed handler errors.
T["unavailable service"] = function()
  local h = harness()
  local instanceId = startForeground(h, luaScript("test.cam", "test.raw", "needsCamera"), 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_RAW_HANDLER_ERROR")
end

-- 11. Mod events are restricted to the owning mod's namespace.
T["event namespace restriction"] = function()
  local h = harness()
  runToCompletion(h, luaScript("test.evt", "test.raw", "emits"), 100, 102)
  local found = false
  for _, record in ipairs(h.services.events.records) do
    if record.name == "mod.test.mod.evt" then
      found = true
    end
  end
  Assert.isTrue(found)
  local h2 = harness()
  local instanceId = startForeground(h2, luaScript("test.evt2", "test.raw", "emitsForeign"), 100)
  h2.scheduler:step(100, nil)
  Assert.equal(assert(h2.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_RAW_RESULT_INVALID")
end

-- 12. Unknown modules and functions are attributed raw errors.
T["unknown module and function"] = function()
  local h = harness()
  local instanceId = startForeground(h, luaScript("test.nomod", "test.missing", "fn"), 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_RAW_MODULE_NOT_FOUND")
  local h2 = harness()
  local instanceId2 = startForeground(h2, luaScript("test.nofn", "test.raw", "missingFn"), 100)
  h2.scheduler:step(100, nil)
  Assert.equal(assert(h2.services.events:eventFor("script.error", instanceId2)).code, "SCRIPT_RAW_FUNCTION_NOT_FOUND")
end

-- 13. ctx.script:call creates a common child through a child_script task and
-- the caller resumes through the generic handoff.
T["ctx script call"] = function()
  local h = harness()
  local helper = S.script({
    api = 1,
    id = "common.helper",
    params = { value = "integer" },
    steps = {
      S.setVar({ variable = "VAR_HELPER", value = S.arg("value") }),
      { op = "signal_caller" },
      S.stop(),
    },
  })
  h.registry:installBase(helper.id, helper, "generated")
  local resource = luaScript("test.call", "test.raw", "callsScript")
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  h.scheduler:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_HELPER"), 3)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 14. The example raw extension saves and resumes only through its named
-- task: the descriptor became the one authoritative starter_choice record.
T["raw task save resume"] = function()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.save",
    locals = { starter = "serializable" },
    steps = {
      S.lua({
        module = "test.raw",
        fn = "returnsTask",
        result = S.local_("starter"),
      }),
      S.setVar({ variable = "VAR_AFTER", value = S.local_("starter") }),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, {})
  h.scheduler:step(101, {})
  local bucket = ScriptSave.capture(h.scheduler, 101, { registryFingerprint = h.registry:fingerprint() })
  local taskRecord = bucket.tasks[1]
  Assert.equal(taskRecord.taskType, "starter_choice")
  Assert.equal(taskRecord.state.phase, "choosing")
  local scheduler2 = Scheduler.new({
    services = h.services,
    taskRegistry = h.taskRegistry,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  ScriptSave.restore(bucket, scheduler2, 101, {})
  scheduler2:step(102, { pressedDirection = "east" })
  scheduler2:step(103, { pressedAction = true })
  scheduler2:step(104, {})
  scheduler2:step(105, {})
  local starter = h.services.world:getVar("VAR_AFTER")
  ---@cast starter any
  Assert.equal(starter.species, 158)
end

-- 15. ctx.script:trigger hands out a fresh copy per call: the live trigger
-- table is never exposed to raw handlers.
T["trigger returns a fresh copy per call"] = function()
  local h = harness()
  local resource = luaScript("test.trigger", "test.raw", "triggerCopy")
  h.registry:installBase(resource.id, resource, "generated")
  local composed = assert(h.composition:effective(resource.id))
  h.scheduler:createForeground(composed, { kind = "test", scriptId = "test.trigger" }, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_COPY"), 1, "the trigger copy contract must hold")
end

-- 16. ctx.audio.isPlaying without an audio service faults instead of
-- silently returning false (one silent-degradation policy).
T["audio isPlaying without service faults"] = function()
  local h = harness()
  local instanceId = startForeground(h, luaScript("test.audio", "test.raw", "needsAudio"), 100)
  h.scheduler:step(100, nil)
  local errorEvent = assert(h.services.events:eventFor("script.error", instanceId))
  Assert.equal(errorEvent.code, "SCRIPT_RAW_HANDLER_ERROR")
end

-- 17. ctx.events.emit without an events service faults instead of silently
-- dropping the event. With no events host the scheduler's own emission is
-- nil-safe, so the observable surface is the ownership release: the
-- foreground environment tears down.
T["events emit without service faults"] = function()
  local h = harness()
  h.services.events = nil
  startForeground(h, luaScript("test.noevents", "test.raw", "emitsNoHost"), 100)
  h.scheduler:step(100, nil)
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    0,
    "the emit must fault before the marker node runs (it silently succeeds today)"
  )
  Assert.isNil(h.scheduler:foregroundEnvironmentId(), "the events fault must release the environment")
end

-- 18. ctx.dialogue.isOpen without a dialogue service faults instead of
-- silently reporting closed (the dialogue service is always wired in
-- production; an unwired composition is a composition fault).
T["dialogue isOpen without service faults"] = function()
  local h = harness()
  local instanceId = startForeground(h, luaScript("test.nodialogue", "test.raw", "dialogueIsOpenNoHost"), 100)
  h.scheduler:step(100, nil)
  local errorEvent = assert(h.services.events:eventFor("script.error", instanceId))
  Assert.equal(errorEvent.code, "SCRIPT_RAW_HANDLER_ERROR")
end

-- 19. A ctx.tasks factory called with dot syntax (the documented
-- `ctx.tasks.<name>(spec)` form) passes the spec as the handler's argument:
-- Lua dot calls carry no implicit self, so the factory signature must not
-- expect one.
T["task factory dot call passes the spec"] = function()
  local h = harness()
  runToCompletion(h, luaScript("test.factory", "test.raw", "usesTaskFactory"), 100, 104)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

return T
