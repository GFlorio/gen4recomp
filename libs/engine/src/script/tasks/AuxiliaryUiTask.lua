-- Waits for the logical auxiliary field UI to reach a requested visibility.
-- The state owner lives in the field runtime, so this task owns no resource.

local AuxiliaryUiTask = {}

AuxiliaryUiTask.type = "auxiliary_ui"
AuxiliaryUiTask.version = 1

---@param spec table
---@param ctx table
---@return table
function AuxiliaryUiTask.create(spec, ctx)
  local visible = spec.node and spec.node.visible
  assert(type(visible) == "boolean", "auxiliary_ui requires a visibility boolean")
  local auxiliary = assert(ctx.services.auxiliaryUi, "auxiliary UI service is unavailable")
  auxiliary:requestVisible(visible)
  return { visible = visible }
end

---@param state table
---@param ctx table
---@return table
function AuxiliaryUiTask.poll(state, ctx)
  local auxiliary = assert(ctx.services.auxiliaryUi, "auxiliary UI service is unavailable")
  local expected = state.visible and "shown" or "hidden"
  local status = auxiliary:status()
  if status.requested ~= expected then
    auxiliary:requestVisible(state.visible)
    status = auxiliary:status()
  end
  if status.state == expected then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table
---@return nil
function AuxiliaryUiTask.validate(state)
  assert(type(state) == "table" and type(state.visible) == "boolean", "auxiliary_ui task state is invalid")
  return nil
end

return AuxiliaryUiTask
