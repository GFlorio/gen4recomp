-- warp task implementation : a blocking map
-- transition integrated with the field transition subsystem. The task starts
-- the transition through the maps service, polls its completion (the
-- transition is engine-owned asynchronous work), and graph continuation
-- follows the generic one-tick handoff. Every scalar_or_value operand is
-- evaluated against the world before the target is forwarded, and a failed
-- transition yields a faulted result so the script never continues as though
-- the warp succeeded. Warps are foreground-only.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local Runtime = require("libs.engine.src.script.Runtime")

local WarpTask = {}

WarpTask.type = "warp"
WarpTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function WarpTask.create(spec, ctx)
  local node = assert(spec.node, "warp task requires its graph node")
  local maps = assert(ctx.services.maps, "warp task requires the maps service")
  local run = { services = ctx.services, instance = ctx.instance }
  local target = {
    map = Runtime.evaluateValue(node.map, run),
    warp = Runtime.evaluateValue(node.warp, run),
    fieldX = Runtime.evaluateValue(node.fieldX, run),
    fieldZ = Runtime.evaluateValue(node.fieldZ, run),
    facing = Runtime.evaluateValue(node.facing, run),
  }
  maps:startWarp(target)
  return { target = target }
end

---@param state table
---@param ctx table
---@return table
function WarpTask.poll(state, ctx)
  local maps = assert(ctx.services.maps, "warp task requires the maps service")
  if maps:warpDone() then
    local transitionError = maps:pendingError()
    if transitionError ~= nil then
      -- The transition failed while the screen was black: fault the script
      -- instead of continuing as though the warp succeeded.
      local fault
      if Errors.is(transitionError) then
        fault = transitionError
      else
        fault = Errors.new(ScriptErrors.SCRIPT_WARP_FAILED, tostring(transitionError), {
          scriptId = ctx.instance.scriptId,
          taskId = ctx.taskId,
        })
      end
      return {
        complete = true,
        state = state,
        result = { termination = "faulted", error = fault },
      }
    end
    return { complete = true, state = state, result = { warped = true } }
  end
  return { complete = false, state = state }
end

---@param state table
---@param reason string
function WarpTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function WarpTask.validate(state)
  if type(state) ~= "table" or type(state.target) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "warp state must hold its target", { state = state })
  end
  return nil
end

return WarpTask
