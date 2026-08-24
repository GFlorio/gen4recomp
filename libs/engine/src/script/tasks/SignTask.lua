-- sign task implementation : the native waiter
-- for the high-level S.sign / S.trainerTip operations. The runtime handler
-- opens the presentation in-handler (style routing, SHOW, and the instant or
-- typed print through the injected signpost host — the same
-- ScriptSignpostHost / FieldSignpostController primitives the imported
-- operations use, no second state machine), so creation records no state at
-- all. The poll reads only the fixed-tick input edges: a
-- directional edge closes the window and turns the player (the source
-- interruption for a live typed print, the dismissal otherwise); an A/B
-- edge before the live typed print is done is left to the shared printer
-- policy for trainer tips; it never dismisses. The task carries no result
-- reference. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local SignpostAccess = require("libs.engine.src.script.tasks.SignpostAccess")

local SignTask = {}

SignTask.type = "sign"
SignTask.version = 1

---@param spec table
---@return table state
function SignTask.create(spec)
  local node = assert(spec.node, "sign task requires its graph node")
  return node.op == "trainer_tip" and { typed = true } or {}
end

---@param state table
---@param ctx table
---@return table
function SignTask.poll(state, ctx)
  local host = SignpostAccess.requireSignpost(ctx)
  local input = ctx.input or {}
  if input.pressedDirection then
    ctx.services.player:turn(input.pressedDirection)
    host:close()
    return { complete = true, state = state }
  end
  if input.pressedAction or input.pressedCancel then
    if host:isPrintDone() then
      host:close()
      return { complete = true, state = state }
    end
    -- A/B before a live typed print is done is handled by the shared printer
    -- policy; the task keeps waiting for the dismissal edge.
    if not state.typed then
      host:finishPrint()
    end
    return { complete = false, state = state }
  end
  return { complete = false, state = state }
end

-- Fault/cancellation cleanup: the task owns the presented window, so
-- closing the signpost clears the printer, hides the window, returns the
-- command to nop, restores the default style, and releases modal ownership
-- exactly once.
---@param state table
---@param reason string
---@param ctx table|nil
function SignTask.cancel(state, reason, ctx)
  SignpostAccess.closeOnCancel(state, reason, ctx)
end

---@param state table
---@return Errors.Error|nil
function SignTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "sign state must be a table", { state = state })
  end
  return nil
end

return SignTask
