-- wait_signpost_action task implementation : the
-- native waiter for opcode 58 (WaitSignpostAction). It polls the injected
-- signpost host's semantic idle query each eligible tick and completes only
-- when the command is idle — never on a fixed tick count — because the
-- fixed-tick signpost controller returns the command to idle only when the
-- scheduled action finishes (the wipe endpoint-check update, or the SHOW/
-- HIDE completion update). The task carries no result reference (opcode 58
-- has no result operand) and no serializable state. On cancellation the task
-- closes the signpost it blocks on, releasing the presented window. Pure
-- domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local SignpostAccess = require("libs.hgss.src.script.tasks.SignpostAccess")

local WaitSignpostActionTask = {}

WaitSignpostActionTask.type = "wait_signpost_action"
WaitSignpostActionTask.version = 1

---@return table state
function WaitSignpostActionTask.create()
  return {}
end

-- Complete exactly when the signpost command is idle. The signpost host
-- service is required: a missing service is an attributed fault, never a
-- silent completion. The idle spelling is the controller's own protocol; the
-- task asks the semantic query.
---@param state table
---@param ctx table
---@return table
function WaitSignpostActionTask.poll(state, ctx)
  local host = SignpostAccess.requireSignpost(ctx)
  if host:isCommandIdle() then
    return { complete = true, state = state }
  end
  return { complete = false, state = state }
end

-- Fault/cancellation cleanup: the task owns the presented signpost window it
-- blocks on, so closing the host releases the window, printer, command, and
-- style exactly once. A task that already completed owns nothing.
---@param state table
---@param reason string
---@param ctx table|nil
function WaitSignpostActionTask.cancel(state, reason, ctx)
  SignpostAccess.closeOnCancel(state, reason, ctx)
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
