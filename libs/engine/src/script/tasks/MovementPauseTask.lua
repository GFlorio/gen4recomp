-- movement_pause task implementation: the native-style pause wait behind
-- `lock_all` when actors must finish their current step before pausing. The
-- task completes on its first eligible poll and graph continuation follows
-- the generic one-tick handoff. Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local MovementPauseTask = {}

MovementPauseTask.type = "movement_pause"
MovementPauseTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function MovementPauseTask.create(spec, ctx)
  return { paused = true }
end

---@param state table
---@param ctx table
---@return table
function MovementPauseTask.poll(state, ctx)
  return { complete = true, state = state, result = { paused = true } }
end

---@param state table
---@return Errors.Error|nil
function MovementPauseTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "movement pause state must be a table",
      { state = state }
    )
  end
  return nil
end

return MovementPauseTask
