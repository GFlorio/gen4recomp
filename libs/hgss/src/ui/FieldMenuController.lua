-- Pure field-menu state machine. It owns item selection, completion, and
-- pointer capture while leaving message resolution, layout, rendering, and
-- physical input mapping to its callers.

---@class FieldMenuController
---@field _items table<integer, FieldMenuController.Item>
---@field _itemCount integer
---@field _selectedIndex integer
---@field _cancellable boolean
---@field _cancelValue any
---@field _state "active"|"complete"
---@field _result any
---@field _cancelled boolean
---@field _pressedPointerItem integer?
local FieldMenuController = {}
FieldMenuController.__index = FieldMenuController

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

---@param items table
---@return table<integer, FieldMenuController.Item>, integer
local function copyItems(items)
  assert(type(items) == "table", "field menu requires an item list")
  local count = #items
  assert(count > 0, "field menu requires at least one item")

  local copied = {}
  for luaIndex = 1, count do
    local item = items[luaIndex]
    assert(type(item) == "table", "field menu item must be a table")
    assert(item.value ~= nil, "field menu item requires a result value")
    copied[luaIndex - 1] = {
      text = item.text,
      value = item.value,
      vanillaMetadata = item.vanillaMetadata,
      metadata = item.metadata,
    }
  end
  return copied, count
end

---@param self FieldMenuController
---@param itemIndex integer?
local function assertItemIndex(self, itemIndex)
  if itemIndex == nil then
    return
  end
  assertInteger(itemIndex, "field menu item index")
  assert(itemIndex >= 0 and itemIndex < self._itemCount, "field menu item index is out of range")
end

---@class FieldMenuController.Spec
---@field items FieldMenuController.Item[]
---@field initialCursor integer?
---@field cancellable boolean?
---@field cancelValue any

---@class FieldMenuController.Item
---@field text any
---@field value any
---@field vanillaMetadata any?
---@field metadata any?

---@param spec FieldMenuController.Spec
---@return FieldMenuController
function FieldMenuController.new(spec)
  assert(type(spec) == "table", "field menu requires a specification")
  local items, itemCount = copyItems(spec.items)
  local initialCursor = spec.initialCursor
  if initialCursor == nil then
    initialCursor = 0
  end
  assertInteger(initialCursor, "field menu initial cursor")
  assert(initialCursor >= 0 and initialCursor < itemCount, "field menu initial cursor is out of range")
  assert(spec.cancellable == nil or type(spec.cancellable) == "boolean", "field menu cancellable must be a boolean")
  assert(spec.cancellable ~= true or spec.cancelValue ~= nil, "cancellable field menu requires a cancellation result")

  return setmetatable({
    _items = items,
    _itemCount = itemCount,
    _selectedIndex = initialCursor,
    _cancellable = spec.cancellable == true,
    _cancelValue = spec.cancelValue,
    _state = "active",
    _result = nil,
    _cancelled = false,
    _pressedPointerItem = nil,
  }, FieldMenuController)
end

---@return boolean
function FieldMenuController:isActive()
  return self._state == "active"
end

---@param result any
---@param cancelled boolean
---@return any
function FieldMenuController:_complete(result, cancelled)
  assert(self._state == "active", "field menu is already complete")
  self._state = "complete"
  self._result = result
  self._cancelled = cancelled
  self._pressedPointerItem = nil
  return result
end

-- Layout resolves directional adjacency, then supplies the stable target item
-- index here. The controller deliberately has no knowledge of rows or columns.

---@param itemIndex integer
function FieldMenuController:focus(itemIndex)
  assertItemIndex(self, itemIndex)
  if self:isActive() then
    self._selectedIndex = assert(itemIndex)
  end
end

---@return any
function FieldMenuController:confirm()
  if not self:isActive() then
    return nil
  end
  return self:_complete(self._items[self._selectedIndex].value, false)
end

---@return any
function FieldMenuController:cancel()
  if not self:isActive() or not self._cancellable then
    return nil
  end
  return self:_complete(self._cancelValue, true)
end

-- Pointer hover changes logical focus but never activates an item.

---@param itemIndex integer?
function FieldMenuController:hover(itemIndex)
  if itemIndex ~= nil then
    self:focus(itemIndex)
  end
end

---@param itemIndex integer?
function FieldMenuController:press(itemIndex)
  assertItemIndex(self, itemIndex)
  if self:isActive() then
    self._pressedPointerItem = itemIndex
  end
end

-- A release commits only when it finishes on the originally pressed item.
-- Any mismatched or outside release discards the capture, preventing a drag
-- across rows from selecting its release target.

---@param itemIndex integer?
---@return any
function FieldMenuController:release(itemIndex)
  assertItemIndex(self, itemIndex)
  if not self:isActive() then
    return nil
  end
  local pressed = self._pressedPointerItem
  self._pressedPointerItem = nil
  if pressed == nil or pressed ~= itemIndex then
    return nil
  end
  self._selectedIndex = pressed
  return self:confirm()
end

---@class FieldMenuController.Status
---@field state "active"|"complete"
---@field selectedIndex integer
---@field result any
---@field cancelled boolean

---@return FieldMenuController.Status
function FieldMenuController:status()
  return {
    state = self._state,
    selectedIndex = self._selectedIndex,
    result = self._result,
    cancelled = self._cancelled,
  }
end

return FieldMenuController
