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
local ScriptErrors = require("libs.script.src.errors")

local WarpTask = {}

WarpTask.type = "warp"
WarpTask.version = 1

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function WarpTask.create(spec, ctx)
  local node = assert(spec.node, "warp task requires its graph node")
  local maps = assert(ctx.services.maps, "warp task requires the maps service")
  local run = { services = ctx.services, instance = ctx.instance, semantics = ctx.semantics }
  local target = {
    map = ctx.semantics.evaluateValue(node.map, run),
    warp = ctx.semantics.evaluateValue(node.warp, run),
    fieldX = ctx.semantics.evaluateValue(node.fieldX, run),
    fieldZ = ctx.semantics.evaluateValue(node.fieldZ, run),
    facing = ctx.semantics.evaluateValue(node.facing, run),
  }
  maps:startWarp(target)
  return { target = target }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
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
        local context = {
          scriptId = ctx.instance.scriptId,
          taskId = ctx.taskId,
        }
        ---@cast context Errors.Context
        fault = Errors.new(ScriptErrors.SCRIPT_WARP_FAILED, tostring(transitionError), context)
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

---@param state table<string, unknown>
---@param reason string
function WarpTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function WarpTask.validate(state)
  if type(state) ~= "table" or type(state.target) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "warp state must hold its target", context)
  end
  return nil
end

return WarpTask
