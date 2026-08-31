-- Selection owns a zero-based selected index for an ordered selectable range.

---@class Selection
---@field private _itemCount integer
---@field private _selectedIndex integer?
local Selection = {}
Selection.__index = Selection

---@param value any
---@param name string
local function assertInteger(value, name)
  assert(
    type(value) == "number"
      and value == value
      and value ~= math.huge
      and value ~= -math.huge
      and value == math.floor(value),
    name .. " must be a finite integer"
  )
end

---@param itemCount integer
local function validateItemCount(itemCount)
  assertInteger(itemCount, "selection item count")
  assert(itemCount >= 0, "selection item count must not be negative")
end

---@param itemCount integer
---@param selectedIndex integer?
---@return Selection
function Selection.new(itemCount, selectedIndex)
  validateItemCount(itemCount)
  if selectedIndex ~= nil then
    assertInteger(selectedIndex, "selection index")
  end
  if itemCount == 0 then
    assert(selectedIndex == nil, "empty selection cannot have a selected index")
  else
    selectedIndex = selectedIndex or 0
    assert(selectedIndex >= 0 and selectedIndex < itemCount, "selection index is out of range")
  end
  return setmetatable({ _itemCount = itemCount, _selectedIndex = selectedIndex }, Selection)
end

---@return integer
function Selection:itemCount()
  return self._itemCount
end

---@return integer?
function Selection:selectedIndex()
  return self._selectedIndex
end

---@return boolean
function Selection:hasSelection()
  return self._selectedIndex ~= nil
end

---@param itemIndex integer
function Selection:setSelectedIndex(itemIndex)
  assertInteger(itemIndex, "selection index")
  assert(self._itemCount > 0, "empty selection cannot have a selected index")
  assert(itemIndex >= 0 and itemIndex < self._itemCount, "selection index is out of range")
  self._selectedIndex = itemIndex
end

---@param delta integer
---@return integer?
function Selection:move(delta)
  assertInteger(delta, "selection movement")
  if self._selectedIndex == nil then
    return nil
  end
  self._selectedIndex = math.max(0, math.min(self._selectedIndex + delta, self._itemCount - 1))
  return self._selectedIndex
end

---@param itemCount integer
function Selection:setItemCount(itemCount)
  validateItemCount(itemCount)
  self._itemCount = itemCount
  if itemCount == 0 then
    self._selectedIndex = nil
  elseif self._selectedIndex == nil then
    self._selectedIndex = 0
  else
    self._selectedIndex = math.min(self._selectedIndex, itemCount - 1)
  end
end

---@return { itemCount: integer, selectedIndex: integer? }
function Selection:status()
  return { itemCount = self._itemCount, selectedIndex = self._selectedIndex }
end

return Selection
