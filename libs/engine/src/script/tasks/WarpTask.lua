-- warp task implementation : a blocking map
-- transition integrated with the field transition subsystem. The task starts
-- the transition through the maps service, polls its completion (the
-- transition is engine-owned asynchronous work), and graph continuation
-- follows the generic one-tick handoff. Warps are foreground-only.
-- Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local WarpTask = {}

WarpTask.type = "warp"
WarpTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function WarpTask.create(spec, ctx)
  local node = assert(spec.node, "warp task requires its graph node")
  local maps = assert(ctx.services.maps, "warp task requires the maps service")
  local target = {
    map = node.map,
    warp = node.warp,
    fieldX = node.fieldX,
    fieldZ = node.fieldZ,
    facing = node.facing,
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
