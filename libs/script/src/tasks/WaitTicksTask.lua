-- wait_ticks task implementation : a
-- native-style pause timer. With a `countdownVariable` the task is
-- var-driven exactly like the source (ScrCmd_Wait writes the frame count
-- into the variable at creation; RunPauseTimer decrements the variable
-- itself once per poll and completes when it reaches zero). Without one the
-- countdown stays in serializable task state. The record's first poll is
-- the creation tick plus one, and graph continuation follows the generic
-- completion handoff (one tick after the successful poll), so
-- `waitTicks(1)` at tick T resumes at T + 2. The variable value lives in
-- the world store, so saves carry it automatically. Pure domain module: no
-- love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local WaitTicksTask = {}

WaitTicksTask.type = "wait_ticks"
WaitTicksTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function WaitTicksTask.create(spec, ctx)
  local ticks = spec.ticks or (spec.node and spec.node.ticks)
  if type(ticks) ~= "number" or ticks < 1 or ticks ~= math.floor(ticks) then
    local context = { ticks = ticks, scriptId = ctx.instance.scriptId }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "wait_ticks requires an integer >= 1", context)
  end
  if spec.countdownVariable ~= nil then
    return { countdownVariable = spec.countdownVariable }
  end
  return { remainingTicks = ticks }
end

-- One decrement per eligible poll; completes when the countdown reaches
-- zero. A countdown variable is the authoritative counter, exactly like
-- the source RunPauseTimer (a later write to the variable is observed and
-- decremented).
---@param state table
---@param ctx table
---@return table
function WaitTicksTask.poll(state, ctx)
  if state.countdownVariable ~= nil then
    local remaining = ctx.services.world:getVar(state.countdownVariable) - 1
    ctx.services.world:setVar(state.countdownVariable, remaining)
    if remaining == 0 then
      return { complete = true, state = state, result = nil }
    end
    return { complete = false, state = state }
  end
  local remaining = state.remainingTicks - 1
  state.remainingTicks = remaining
  if remaining <= 0 then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table
---@return Errors.Error|nil
function WaitTicksTask.validate(state)
  -- The internal form holds remainingTicks >= 0 (zero is the completed
  -- countdown of a completed-but-unconsumed task; the
  -- var-driven form names the countdown variable whose value lives in the
  -- world store.
  if type(state) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "wait_ticks state must be a table", context)
  end
  if state.countdownVariable ~= nil then
    return nil
  end
  if type(state.remainingTicks) ~= "number" or state.remainingTicks < 0 then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "wait_ticks state must hold remainingTicks >= 0",
      context
    )
  end
  return nil
end

return WaitTicksTask
