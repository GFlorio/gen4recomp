-- wait_input task implementation : reads input
-- edges, never held state; the first poll is always a later tick, so the
-- interaction-triggering edge can never satisfy a wait created by the same
-- trigger. `turnPlayerOnDpad` updates the player's facing on a d-pad edge
-- before the task completes. Graph continuation follows the generic handoff
-- (one tick after the successful poll). Pure domain module: no love
-- dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local WaitInputTask = {}

WaitInputTask.type = "wait_input"
WaitInputTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function WaitInputTask.create(spec, ctx)
  local node = spec.node or {}
  local buttons = node.buttons or { "a", "b" }
  for _, button in ipairs(buttons) do
    if button ~= "a" and button ~= "b" then
      local context = { buttons = buttons, scriptId = ctx.instance.scriptId }
      ---@cast context Errors.Context
      Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "wait_input buttons must be a/b", context)
    end
  end
  return {
    buttons = buttons,
    allowDpad = node.allowDpad == true,
    turnPlayerOnDpad = node.turnPlayerOnDpad == true,
    ticks = spec.ticks, -- nil unless the caller supplies an or-ticks fallback
  }
end

-- Read one immutable input edge: the action/cancel buttons (the fixed-tick
-- snapshot's pressedAction/pressedCancel) and optionally the pressed
-- direction.
---@param state table
---@param ctx table
---@return string|nil a|b|direction
local function readEdge(state, ctx)
  local input = ctx.input or {}
  local edge
  for _, button in ipairs(state.buttons) do
    if button == "a" and input.pressedAction then
      edge = "a"
    end
    if button == "b" and input.pressedCancel then
      edge = "b"
    end
  end
  if edge ~= nil then
    return edge
  end
  if state.allowDpad and input.pressedDirection then
    return input.pressedDirection
  end
  return nil
end

---@param state table
---@param ctx table
---@return table
function WaitInputTask.poll(state, ctx)
  local edge = readEdge(state, ctx)
  if edge ~= nil then
    if state.turnPlayerOnDpad and edge ~= "a" and edge ~= "b" then
      ctx.services.player:turn(edge)
    end
    return { complete = true, state = state, result = { edge = edge } }
  end
  if state.ticks ~= nil then
    state.ticks = state.ticks - 1
    if state.ticks <= 0 then
      return { complete = true, state = state, result = { edge = "ticks" } }
    end
  end
  return { complete = false, state = state }
end

---@param state table
---@param reason string
function WaitInputTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function WaitInputTask.validate(state)
  if type(state) ~= "table" or type(state.buttons) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "wait_input state must hold its buttons", context)
  end
  return nil
end

return WaitInputTask
