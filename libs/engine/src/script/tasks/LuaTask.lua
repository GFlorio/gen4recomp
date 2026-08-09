-- lua task implementation : invokes one named
-- raw-Lua handler through the ownership-aware module registry, classifies
-- the result, and either completes synchronously (nil or a serializable
-- value written to the node's declared result ref) or delegates to the
-- returned task descriptor. The delegate's state is polled through this
-- task's own one-poll-per-tick cadence, so raw tasks obey the same creation
-- and handoff rules as native ones (section 21.4): the scheduler assigns all
-- lifecycle fields, the first poll is never the creation tick, and graph
-- continuation follows the generic one-tick handoff. Pure domain module:
-- no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local RawInvocation = require("libs.engine.src.script.RawInvocation")

local LuaTask = {}

LuaTask.type = "lua"
LuaTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function LuaTask.create(spec, ctx)
  local node = assert(spec.node, "lua task requires its graph node")
  local modules = assert(ctx.services.rawModules, "lua task requires the raw module registry in services")
  local classification, value = RawInvocation.invoke({
    modules = modules,
    scheduler = ctx.scheduler,
    instance = ctx.instance,
    environment = ctx.environment,
    services = ctx.services,
    node = node,
    module = node.module,
    fn = node.fn,
    args = node.args,
  })
  local state = {
    phase = classification == "task" and "delegating" or "done",
    result = value,
  }
  if state.phase == "delegating" then
    state.taskType = value.taskType
    state.taskVersion = value.taskVersion
    local impl, resolveErr = ctx.scheduler:resolveTask(state.taskType, state.taskVersion)
    if not impl then
      local err = resolveErr --[[@as Errors.Error]]
      Errors.raise(err.code, err.message, {
        scriptId = ctx.instance.scriptId,
        module = node.module,
        fn = node.fn,
        cause = err,
      })
    end
    -- The descriptor state passes through the task implementation's create so
    -- defaults apply and validation runs with this instance's attribution.
    state.delegateState = impl.create(value.state, ctx)
  end
  return state
end

---@param state table
---@param ctx table
---@return table
function LuaTask.poll(state, ctx)
  if state.phase == "done" then
    return { complete = true, state = state, result = state.result }
  end
  -- Delegating: poll the raw task's state through this record's cadence.
  -- The implementation is re-resolved each poll so task state stays
  -- serializable (save records never carry function tables).
  local impl = assert(ctx.scheduler:resolveTask(state.taskType, state.taskVersion))
  local result = impl.poll(state.delegateState, ctx)
  state.delegateState = result.state
  if result.complete then
    return { complete = true, state = state, result = result.result }
  end
  return { complete = false, state = state }
end

---@param state table
---@param reason string
function LuaTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function LuaTask.validate(state)
  if type(state) ~= "table" or (state.phase ~= "done" and state.phase ~= "delegating") then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "lua state must hold a known phase", { state = state })
  end
  return nil
end

return LuaTask
