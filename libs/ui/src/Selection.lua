-- Selection owns one selected zero-based index in a fixed non-empty range.

---@class Selection
---@field private _itemCount integer
---@field private _selectedIndex integer
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
  assert(itemCount > 0, "selection item count must be positive")
end

---@param itemCount integer
---@param selectedIndex integer?
---@return Selection
function Selection.new(itemCount, selectedIndex)
  validateItemCount(itemCount)
  if selectedIndex == nil then
    selectedIndex = 0
  end
  assertInteger(selectedIndex, "selection index")
  assert(selectedIndex >= 0 and selectedIndex < itemCount, "selection index is out of range")
  return setmetatable({ _itemCount = itemCount, _selectedIndex = selectedIndex }, Selection)
end

---@return integer
function Selection:itemCount()
  return self._itemCount
end

---@return integer
function Selection:selectedIndex()
  return self._selectedIndex
end

---@param itemIndex integer
function Selection:setSelectedIndex(itemIndex)
  assertInteger(itemIndex, "selection index")
  assert(itemIndex >= 0 and itemIndex < self._itemCount, "selection index is out of range")
  self._selectedIndex = itemIndex
end

return Selection
