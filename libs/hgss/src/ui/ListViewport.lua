-- ListViewport owns the first visible row needed to keep a selection in view.

---@class ListViewport
---@field _itemCount integer
---@field _visibleRows integer
---@field _selectedIndex integer?
---@field _firstVisibleRow integer
local ListViewport = {}
ListViewport.__index = ListViewport

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
  assertInteger(itemCount, "list viewport item count")
  assert(itemCount >= 0, "list viewport item count must not be negative")
end

---@param visibleRows integer
local function validateVisibleRows(visibleRows)
  assertInteger(visibleRows, "list viewport visible row count")
  assert(visibleRows > 0, "list viewport visible row count must be positive")
end

---@param self ListViewport
local function normalize(self)
  if self._itemCount == 0 then
    self._selectedIndex = nil
    self._firstVisibleRow = 0
    return
  end
  self._selectedIndex = self._selectedIndex or 0
  self._selectedIndex = math.min(self._selectedIndex, self._itemCount - 1)
  local maximumFirst = math.max(0, self._itemCount - self._visibleRows)
  self._firstVisibleRow = math.min(self._firstVisibleRow, maximumFirst)
  if self._selectedIndex < self._firstVisibleRow then
    self._firstVisibleRow = self._selectedIndex
  elseif self._selectedIndex >= self._firstVisibleRow + self._visibleRows then
    self._firstVisibleRow = self._selectedIndex - self._visibleRows + 1
  end
end

---@param options { itemCount: integer, visibleRows: integer, selectedIndex: integer? }
---@return ListViewport
function ListViewport.new(options)
  assert(type(options) == "table", "list viewport options are required")
  validateItemCount(options.itemCount)
  validateVisibleRows(options.visibleRows)
  if options.selectedIndex ~= nil then
    assertInteger(options.selectedIndex, "list viewport selected index")
    assert(
      options.itemCount > 0 and options.selectedIndex >= 0 and options.selectedIndex < options.itemCount,
      "list viewport selected index is out of range"
    )
  end
  local self = setmetatable({
    _itemCount = options.itemCount,
    _visibleRows = options.visibleRows,
    _selectedIndex = options.selectedIndex,
    _firstVisibleRow = 0,
  }, ListViewport)
  normalize(self)
  return self
end

---@return integer
function ListViewport:itemCount()
  return self._itemCount
end

---@return integer
function ListViewport:visibleRows()
  return self._visibleRows
end

---@return integer?
function ListViewport:selectedIndex()
  return self._selectedIndex
end

---@return integer?
function ListViewport:firstVisibleRow()
  if self._itemCount == 0 then
    return nil
  end
  return self._firstVisibleRow
end

---@return integer?
function ListViewport:lastVisibleRow()
  if self._itemCount == 0 then
    return nil
  end
  return math.min(self._itemCount - 1, self._firstVisibleRow + self._visibleRows - 1)
end

---@return { first: integer?, last: integer? }
function ListViewport:visibleRange()
  return { first = self:firstVisibleRow(), last = self:lastVisibleRow() }
end

---@param itemIndex integer
function ListViewport:setSelectedIndex(itemIndex)
  assertInteger(itemIndex, "list viewport selected index")
  assert(self._itemCount > 0, "empty list viewport cannot have a selected index")
  assert(itemIndex >= 0 and itemIndex < self._itemCount, "list viewport selected index is out of range")
  self._selectedIndex = itemIndex
  normalize(self)
end

---@param itemCount integer
function ListViewport:setItemCount(itemCount)
  validateItemCount(itemCount)
  self._itemCount = itemCount
  normalize(self)
end

---@param visibleRows integer
function ListViewport:setVisibleRows(visibleRows)
  validateVisibleRows(visibleRows)
  self._visibleRows = visibleRows
  normalize(self)
end

---@return { itemCount: integer, visibleRows: integer, selectedIndex: integer?, firstVisibleRow: integer?, lastVisibleRow: integer? }
function ListViewport:status()
  return {
    itemCount = self._itemCount,
    visibleRows = self._visibleRows,
    selectedIndex = self._selectedIndex,
    firstVisibleRow = self:firstVisibleRow(),
    lastVisibleRow = self:lastVisibleRow(),
  }
end

return ListViewport
