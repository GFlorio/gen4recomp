-- Pure rectangular button geometry for host-rendered controls.

local Button = {}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function rectangle(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite numbers")
  end
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function metric(value, name)
  assert(finite(value) and value >= 0, name .. " must be a finite non-negative number")
  return value
end

local function assertPositiveRectangle(value, name)
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
end

local function assertFiniteRectangle(value, name)
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite")
  end
  assert(value.width >= 0 and value.height >= 0, name .. " dimensions must be non-negative")
end

---@param spec table
---@return table
function Button.resolve(spec)
  assert(type(spec) == "table", "button specification is required")
  local rect = rectangle(spec.rect, "button rectangle")
  local bevelWidth = metric(spec.bevelWidth, "button bevel width")
  local contentInsetX = metric(spec.contentInsetX, "button horizontal content inset")
  local contentInsetY = metric(spec.contentInsetY, "button vertical content inset")

  local faceRect = {
    x = rect.x + bevelWidth,
    y = rect.y + bevelWidth,
    width = rect.width - bevelWidth * 2,
    height = rect.height - bevelWidth * 2,
  }
  assertPositiveRectangle(faceRect, "button face rectangle")
  assertFiniteRectangle(faceRect, "button face rectangle")

  local contentRect = {
    x = faceRect.x + contentInsetX,
    y = faceRect.y + contentInsetY,
    width = faceRect.width - contentInsetX * 2,
    height = faceRect.height - contentInsetY * 2,
  }
  assertPositiveRectangle(contentRect, "button content rectangle")
  assertFiniteRectangle(contentRect, "button content rectangle")

  local top = { x = rect.x, y = rect.y, width = rect.width, height = bevelWidth }
  local left = {
    x = rect.x,
    y = rect.y + bevelWidth,
    width = bevelWidth,
    height = rect.height - bevelWidth * 2,
  }
  local bottom = {
    x = rect.x,
    y = rect.y + rect.height - bevelWidth,
    width = rect.width,
    height = bevelWidth,
  }
  local right = {
    x = rect.x + rect.width - bevelWidth,
    y = rect.y + bevelWidth,
    width = bevelWidth,
    height = rect.height - bevelWidth * 2,
  }
  for name, edge in pairs({ top = top, left = left, bottom = bottom, right = right }) do
    assertFiniteRectangle(edge, "button " .. name .. " edge")
  end

  return {
    rect = rect,
    faceRect = faceRect,
    contentRect = contentRect,
    top = top,
    left = left,
    bottom = bottom,
    right = right,
  }
end

---@param button table
---@param x number
---@param y number
---@return boolean
function Button.contains(button, x, y)
  assert(type(button) == "table" and type(button.rect) == "table", "resolved button is required")
  assert(finite(x) and finite(y), "button hit point must be finite")
  local rect = button.rect
  assert(
    finite(rect.x) and finite(rect.y) and finite(rect.width) and finite(rect.height),
    "resolved button rectangle is invalid"
  )
  assert(rect.width > 0 and rect.height > 0, "resolved button rectangle must be positive")
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

return Button
