-- fade task implementation : `wait_fade` blocks on
-- the screen fade started by `fade_screen`. The fade advances in the
-- engine-owned asynchronous phase (the transition/fade system); the task
-- polls the screen service for completion and falls back to a documented
-- duration when the backend cannot report progress. Graph continuation
-- follows the generic one-tick handoff. Pure domain module: no love
-- dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local FadeTask = {}

FadeTask.type = "fade"
FadeTask.version = 1

-- Fallback full-fade duration in ticks at 30 Hz when the backend cannot
-- report progress.
FadeTask.FALLBACK_TICKS = 30

---@param spec table
---@param ctx table
---@return table state
function FadeTask.create(spec, ctx)
  return { fallbackTicks = nil }
end

---@param state table
---@param ctx table
---@return table
function FadeTask.poll(state, ctx)
  local screen = ctx.services.screen
  if screen ~= nil and screen.fadeDone ~= nil then
    local done = screen:fadeDone()
    if done ~= nil then
      if done then
        return { complete = true, state = state, result = { completed = true } }
      end
      return { complete = false, state = state }
    end
  end
  if state.fallbackTicks == nil then
    state.fallbackTicks = FadeTask.FALLBACK_TICKS
  end
  state.fallbackTicks = state.fallbackTicks - 1
  if state.fallbackTicks <= 0 then
    return {
      complete = true,
      state = state,
      result = {
        completed = true,
        fallback = true,
        diagnostic = "screen backend cannot report fade progress; used catalog duration",
      },
    }
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
