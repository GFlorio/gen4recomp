-- fade task implementation : `wait_fade` blocks on
-- the screen fade started by `fade_screen`. The fade advances in the
-- engine-owned asynchronous phase (the transition/fade system); the task
-- polls the screen service for completion, and a backend that cannot report
-- progress is a fault, never a simulated duration. Graph continuation
-- follows the generic one-tick handoff. Pure domain module: no love
-- dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local FadeTask = {}

FadeTask.type = "fade"
FadeTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function FadeTask.create(spec, ctx)
  local screen = ctx.services.screen
  if screen == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the fade task requires the screen service",
      { scriptId = ctx.instance.scriptId }
    )
  end
  if type(screen.fadeDone) ~= "function" then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the screen service must report fade progress",
      { scriptId = ctx.instance.scriptId }
    )
  end
  return {}
end

---@param state table
---@param ctx table
---@return table
function FadeTask.poll(state, ctx)
  local screen = ctx.services.screen
  if screen == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the fade task requires the screen service")
  end
  local done = screen:fadeDone()
  if done == nil then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "the screen service cannot report fade progress")
  end
  if done then
    return { complete = true, state = state, result = { completed = true } }
  end
  return { complete = false, state = state }
end

---@param state table
---@param reason string
function FadeTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function FadeTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "fade state must be a table", { state = state })
  end
  return nil
end

return FadeTask
