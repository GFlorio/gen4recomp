-- child_script task implementation: the native-style handoff between a
-- caller blocked on `call_common` and its verified common-script child
-- context. The task watches the environment's caller signal (the source
-- `ScrNative_WaitStd` bit protocol) and the child's termination state; it
-- completes only on a later poll, and the caller's graph continuation follows
-- the generic handoff (one tick after that poll). A faulted child propagates
-- as a faulted result so the scheduler aborts the blocked parent with
-- attribution. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local ChildScriptTask = {}

ChildScriptTask.type = "child_script"
ChildScriptTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function ChildScriptTask.create(spec, ctx)
  if spec.scriptId ~= nil then
    -- Raw `ctx.script:call` form: resolve the composed script, allocate the
    -- child context now, and watch it like a translated common call.
    local composed = ctx.scheduler:resolveComposition(spec.scriptId)
    if composed == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_CALL_TARGET_MISSING,
        "no composed script for " .. spec.scriptId,
        { scriptId = ctx.instance.scriptId, target = spec.scriptId }
      )
    end
    local child, slot, parentSlot = ctx.scheduler:createCommonChild(composed, spec.args or {}, ctx)
    return {
      childInstanceId = child.instanceId,
      childSlot = slot,
      parentSlot = parentSlot,
    }
  end
  assert(
    spec.childInstanceId and spec.childSlot ~= nil and spec.parentSlot ~= nil,
    "child_script requires child and parent slot identity"
  )
  return {
    childInstanceId = spec.childInstanceId,
    childSlot = spec.childSlot,
    parentSlot = spec.parentSlot,
  }
end

-- Completes when the caller's signal bit is cleared (the child called
-- `signal_caller`) or the child context terminated. A faulted child yields a
-- faulted result; the scheduler converts it into an attributed parent fault.
---@param state table
---@param ctx table
---@return table
function ChildScriptTask.poll(state, ctx)
  local child = ctx.scheduler:instance(state.childInstanceId)
  if child == nil or child.status == "cancelled" then
    return { complete = true, state = state, result = { termination = "cancelled" } }
  end
  if child.status == "faulted" then
    return {
      complete = true,
      state = state,
      result = {
        termination = "faulted",
        error = Errors.new(
          child.endReason or ScriptErrors.SCRIPT_CALLER_SIGNAL_INVALID,
          "common child faulted: " .. tostring(child.endReason or "unknown"),
          { scriptId = child.scriptId, instanceId = child.instanceId, reason = child.endReason }
        ),
      },
    }
  end
  local signaled = ctx.environment:callerSignal(state.parentSlot) == false
  if signaled or child.status == "completed" then
    return {
      complete = true,
      state = state,
      result = {
        termination = signaled and "signaled" or "terminated",
        childInstanceId = state.childInstanceId,
        childStatus = child.status,
      },
    }
  end
  return { complete = false, state = state }
end

---@param state table
---@return Errors.Error|nil
function ChildScriptTask.validate(state)
  if type(state) ~= "table" or type(state.childInstanceId) ~= "string" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "child_script state must name its child instance",
      context
    )
  end
  return nil
end

return ChildScriptTask
