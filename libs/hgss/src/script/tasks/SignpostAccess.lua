-- Shared host lookup for the signpost task implementations: one attributed
-- fault boundary for the required signpost service, so no task re-derives
-- the attribution. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local SignpostAccess = {}

-- The signpost host from a task context, or an attributed fault when the
-- service is unavailable. The scheduler always injects the service into
-- task contexts; a missing one is a composition failure, never a silent
-- skip.
---@param ctx table<string, unknown>
---@return ScriptSignpostHost
function SignpostAccess.requireSignpost(ctx)
  local host = ctx.services.signpost
  if host == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "signpost service is unavailable",
      { scriptId = ctx.instance.scriptId }
    )
  end
  return host --[[@as ScriptSignpostHost]]
end

-- Shared fault/cancellation teardown for the signpost task implementations:
-- records the cancellation reason and closes the signpost the task owns
-- when the live task context still carries the service (the scheduler
-- injects it into live contexts; a nil context is a teardown path).
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function SignpostAccess.closeOnCancel(state, reason, ctx)
  state.cancelled = reason
  if ctx ~= nil and ctx.services ~= nil and ctx.services.signpost ~= nil then
    ctx.services.signpost:close()
  end
end

return SignpostAccess
