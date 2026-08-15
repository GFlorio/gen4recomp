-- wait_signpost task implementation : the native
-- waiter for opcode 60 (WaitSignpost). It always blocks — there is no
-- same-tick path — and completes on the source dismissal edges
-- (ScrCmd_WaitSignpost / NativeScript_WaitSignpost, src/scrcmd_c.c at the
-- pinned decomp commit): A/B close the window and complete 0 without turning
-- the player; a directional edge additionally turns the player to the
-- pressed direction, closes the window, and completes 0. The completion
-- value flows through the scheduler result reference (node.result), never a
-- direct world write. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local SignpostAccess = require("libs.engine.src.script.tasks.SignpostAccess")

local WaitSignpostTask = {}

WaitSignpostTask.type = "wait_signpost"
WaitSignpostTask.version = 1

---@param spec table
---@return table state
function WaitSignpostTask.create(spec)
  assert(spec.node, "wait signpost requires its graph node")
  return { waiting = true }
end

---@param state table
---@param ctx table
---@return table
function WaitSignpostTask.poll(state, ctx)
  local host = SignpostAccess.requireSignpost(ctx)
  local input = ctx.input or {}
  if input.pressedAction or input.pressedCancel then
    host:close()
    return { complete = true, state = state, result = 0 }
  end
  if input.pressedDirection then
    -- A directional dismissal turns the player before the window closes.
    ctx.services.player:turn(input.pressedDirection)
    host:close()
    return { complete = true, state = state, result = 0 }
  end
  return { complete = false, state = state }
end

-- Fault/cancellation cleanup: the task owns the presented window it waits
-- on, so closing the signpost hides the window, returns the command to nop,
-- and releases modal ownership exactly once.
---@param state table
---@param reason string
---@param ctx table|nil
function WaitSignpostTask.cancel(state, reason, ctx)
  SignpostAccess.closeOnCancel(state, reason, ctx)
end

---@param state table
---@return Errors.Error|nil
function WaitSignpostTask.validate(state)
  if type(state) ~= "table" or state.waiting ~= true then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "wait_signpost state must hold the waiting marker",
      { state = state }
    )
  end
  return nil
end

return WaitSignpostTask
