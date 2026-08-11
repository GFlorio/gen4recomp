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

function ContextChoiceProvider:open()
  assert(self._choice == nil, "a contextual choice is already active")
  self._choice = { selected = 0 }
end

---@return { state: "active", selected: integer }|nil
function ContextChoiceProvider:status()
  if self._choice == nil then
    return nil
  end
  return { state = "active", selected = self._choice.selected }
end

---@param direction string
function ContextChoiceProvider:select(direction)
  assert(self._choice ~= nil, "no contextual choice is active")
  if direction == "left" or direction == "up" or direction == "west" or direction == "north" then
    self._choice.selected = 0
  elseif direction == "right" or direction == "down" or direction == "east" or direction == "south" then
    self._choice.selected = 1
  end
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
