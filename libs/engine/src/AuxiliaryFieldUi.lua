-- Logical auxiliary field UI visibility. It keeps script-visible transitions
-- deterministic even on platforms that have no auxiliary HUD to render.

---@class AuxiliaryFieldUi
---@field private _requested "shown"|"hidden"
---@field private _state "shown"|"showing"|"hidden"|"hiding"
local AuxiliaryFieldUi = {}
AuxiliaryFieldUi.__index = AuxiliaryFieldUi

---@return AuxiliaryFieldUi
function AuxiliaryFieldUi.new()
  return setmetatable({
    _requested = "shown",
    _state = "shown",
  }, AuxiliaryFieldUi)
end

---@return { requested: "shown"|"hidden", state: "shown"|"showing"|"hidden"|"hiding" }
function AuxiliaryFieldUi:capture()
  return self:status()
end

---@param record table
---@return AuxiliaryFieldUi
function AuxiliaryFieldUi.restore(record)
  assert(type(record) == "table", "auxiliary UI state must be a table")
  assert(record.requested == "shown" or record.requested == "hidden", "auxiliary UI request is invalid")
  assert(
    record.state == "shown" or record.state == "showing" or record.state == "hidden" or record.state == "hiding",
    "auxiliary UI state is invalid"
  )
  assert(
    (record.requested == "shown") == (record.state == "shown" or record.state == "showing"),
    "auxiliary UI request and state disagree"
  )
  return setmetatable({ _requested = record.requested, _state = record.state }, AuxiliaryFieldUi)
end

---@return { requested: "shown"|"hidden", state: "shown"|"showing"|"hidden"|"hiding" }
function AuxiliaryFieldUi:status()
  return { requested = self._requested, state = self._state }
end

-- Requests visibility. Hiding an already-hidden UI completes immediately;
-- showing deliberately creates a transition even from the shown state, which
-- preserves HGSS opcode 747's asynchronous script boundary.
---@param visible boolean
---@return boolean pending
function AuxiliaryFieldUi:requestVisible(visible)
  assert(type(visible) == "boolean", "auxiliary UI visibility must be boolean")
  if not visible and self._state == "hidden" then
    self._requested = "hidden"
    return false
  end
  self._requested = visible and "shown" or "hidden"
  self._state = visible and "showing" or "hiding"
  return true
end

-- Advances one fixed visibility transition. A presentation adapter may mirror
-- this state later; no renderer is required for the logical transition.
function AuxiliaryFieldUi:advance()
  if self._state == "showing" then
    self._state = "shown"
  elseif self._state == "hiding" then
    self._state = "hidden"
  end
end

return AuxiliaryFieldUi
