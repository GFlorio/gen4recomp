-- Shared host lookup for the signpost task implementations: one attributed
-- fault boundary for the required signpost service, so no task re-derives
-- the attribution. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local SignpostAccess = {}

-- The signpost host from a task context, or an attributed fault when the
-- service is unavailable. The scheduler always injects the service into
-- task contexts; a missing one is a composition failure, never a silent
-- skip.
---@param ctx table
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

return SignpostAccess
