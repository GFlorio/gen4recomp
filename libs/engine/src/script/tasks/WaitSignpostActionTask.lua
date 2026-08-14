-- wait_signpost_action task implementation : the
-- native waiter for opcode 58 (WaitSignpostAction). It polls the injected
-- signpost host's command each eligible tick and completes only when the
-- command has returned to nop — never on a fixed tick count — because the
-- fixed-tick signpost controller returns the command to nop only when the
-- scheduled action finishes (the wipe endpoint-check update, or the SHOW/
-- HIDE completion update). The task carries no result reference (opcode 58
-- has no result operand) and no serializable state. Pure domain module: no
-- love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local WaitSignpostActionTask = {}

WaitSignpostActionTask.type = "wait_signpost_action"
WaitSignpostActionTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function WaitSignpostActionTask.create(spec, ctx)
  return {}
end

-- Complete exactly when the signpost command is nop. The signpost host
-- service is required: a missing service is an attributed fault, never a
-- silent completion.
---@param state table
---@param ctx table
---@return table
function WaitSignpostActionTask.poll(state, ctx)
  local host = ctx.services.signpost
  if host == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "signpost service is unavailable",
      { scriptId = ctx.instance.scriptId }
    )
  end
  -- LuaLS cannot see through Errors.raise; the raise never returns nil.
  ---@cast host ScriptSignpostHost
  if host:status().command == "nop" then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table
---@return Errors.Error|nil
function WaitSignpostActionTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "wait_signpost_action state must be a table",
      { state = state }
    )
  end
  return nil
end

return WaitSignpostActionTask
