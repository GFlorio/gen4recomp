-- Logical provider for HGSS GetMenuChoice. The command owns a compact
-- contextual two-choice prompt whose result domain is zero for confirm and
-- one for cancel; presentation only observes this state.

---@class ContextChoiceProvider
local ContextChoiceProvider = {}
ContextChoiceProvider.__index = ContextChoiceProvider

---@return ContextChoiceProvider
function ContextChoiceProvider.new()
  return setmetatable({ _choice = nil }, ContextChoiceProvider)
end

---@param selected integer?
function ContextChoiceProvider:open(selected)
  assert(self._choice == nil, "a contextual choice is already active")
  selected = selected or 0
  assert(selected == 0 or selected == 1, "contextual choice selection is invalid")
  self._choice = { selected = selected }
end

---@return { state: "active", selected: integer }|nil
function ContextChoiceProvider:status()
  if self._choice == nil then
    return nil
  end
  return { state = "active", selected = self._choice.selected }
end

---@return boolean
function ContextChoiceProvider:isActive()
  return self._choice ~= nil
end

---@param selected integer
---@return integer selected vanilla result (0 confirm, 1 cancel)
function ContextChoiceProvider:select(selected)
  assert(self._choice ~= nil, "no contextual choice is active")
  assert(selected == 0 or selected == 1, "contextual choice selection is invalid")
  self._choice.selected = selected
  return self._choice.selected
end

---@return integer selected vanilla result (0 confirm, 1 cancel)
function ContextChoiceProvider:confirm()
  assert(self._choice ~= nil, "no contextual choice is active")
  return self._choice.selected
end

function ContextChoiceProvider:close()
  assert(self._choice ~= nil, "no contextual choice is active")
  self._choice = nil
end

return ContextChoiceProvider
