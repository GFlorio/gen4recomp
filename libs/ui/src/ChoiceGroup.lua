-- Pure resolved selectable-item snapshots shared by UI hit testing and painting.

local ChoiceGroup = {}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer(value)
  return finite(value) and value % 1 == 0
end

local function rectangle(value)
  assert(type(value) == "table", "choice rectangle is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), "choice rectangle fields must be finite")
  end
  assert(value.width > 0 and value.height > 0, "choice rectangle must be positive")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function overlaps(first, second)
  return first.x < second.x + second.width
    and second.x < first.x + first.width
    and first.y < second.y + second.height
    and second.y < first.y + first.height
end

function ChoiceGroup.resolve(spec)
  assert(type(spec) == "table", "choice group specification is required")
  assert(type(spec.items) == "table" and #spec.items > 0, "choice group items must be non-empty")
  assert(integer(spec.selectedIndex), "choice group selected index must be an integer")
  assert(spec.selectedIndex >= 0 and spec.selectedIndex < #spec.items, "choice group selected index is out of range")

  local items = {}
  local keys = {}
  for index = 1, #spec.items do
    local item = spec.items[index]
    assert(type(item) == "table", "choice item is required")
    assert(type(item.key) == "string" and item.key ~= "", "choice item key must be non-empty")
    assert(not keys[item.key], "choice item keys must be unique")
    keys[item.key] = true
    items[index] = {
      index = index - 1,
      key = item.key,
      rect = rectangle(item.rect),
      payload = item.payload,
    }
  end
  for first = 1, #items do
    for second = first + 1, #items do
      assert(not overlaps(items[first].rect, items[second].rect), "choice item rectangles must not overlap")
    end
  end

  local resolved = { selectedIndex = spec.selectedIndex, itemCount = #items, items = {} }
  for index, item in ipairs(items) do
    resolved.items[index - 1] = item
  end
  return resolved
end

function ChoiceGroup.hitTest(group, x, y)
  assert(type(group) == "table" and type(group.items) == "table", "choice group is required")
  assert(finite(x) and finite(y), "choice hit point must be finite")
  for index = 0, group.itemCount - 1 do
    local item = assert(group.items[index])
    local itemRect = item.rect
    if x >= itemRect.x and y >= itemRect.y and x < itemRect.x + itemRect.width and y < itemRect.y + itemRect.height then
      return index
    end
  end
  return nil
end

function ChoiceGroup.paint(group, paintList, paintChoice, context)
  assert(type(group) == "table" and type(group.items) == "table", "choice group is required")
  assert(type(paintList) == "table", "choice paint list is required")
  assert(type(paintChoice) == "function", "choice paint callback is required")
  for index = 0, group.itemCount - 1 do
    local item = assert(group.items[index])
    paintChoice(paintList, item, group.selectedIndex == index, context)
  end
end

return ChoiceGroup
