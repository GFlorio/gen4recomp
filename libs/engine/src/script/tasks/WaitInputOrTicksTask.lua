-- wait_input_or_ticks task implementation: the source WaitButtonOrDelay
-- mapping. First completion wins: an input edge completes the wait
-- immediately; otherwise the tick countdown completes after its polls (the
-- generic first-poll rule applies, so a ticks value of 1 completes on the
-- first poll and graph continuation follows one tick later). Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local WaitInputTask = require("libs.engine.src.script.tasks.WaitInputTask")

local WaitInputOrTicksTask = {}

WaitInputOrTicksTask.type = "wait_input_or_ticks"
WaitInputOrTicksTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function WaitInputOrTicksTask.create(spec, ctx)
  local node = assert(spec.node, "wait_input_or_ticks requires its graph node")
  if type(node.ticks) ~= "number" or node.ticks < 1 then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "wait_input_or_ticks requires ticks >= 1",
      { ticks = node.ticks, scriptId = ctx.instance.scriptId }
    )
  end
  local state = WaitInputTask.create(spec, ctx)
  state.ticks = node.ticks
  return state
end

WaitInputOrTicksTask.poll = WaitInputTask.poll
WaitInputOrTicksTask.validate = WaitInputTask.validate

return WaitInputOrTicksTask
