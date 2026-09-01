-- Pure layered button geometry for host-rendered controls.

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

local function insetRect(rect, amount)
  return {
    x = rect.x + amount,
    y = rect.y + amount,
    width = rect.width - amount * 2,
    height = rect.height - amount * 2,
  }
end

local function shape(rect, cornerCut, name)
  assertFiniteRectangle(rect, name .. " rectangle")
  assertPositiveRectangle(rect, name .. " rectangle")
  return { rect = rect, cornerCut = cornerCut }
end

---@param spec table
---@return table
function Button.resolve(spec)
  assert(type(spec) == "table", "button specification is required")
  local rect = rectangle(spec.rect, "button rectangle")
  local borderWidth = metric(spec.borderWidth, "button border width")
  local rimWidth = metric(spec.rimWidth, "button rim width")
  local innerBorderWidth = metric(spec.innerBorderWidth, "button inner border width")
  local cornerCut = metric(spec.cornerCut, "button corner cut")
  assert(cornerCut <= math.min(rect.width, rect.height) / 2, "button corner cut is too large")
  assert(
    finite(spec.faceSplit) and spec.faceSplit > 0 and spec.faceSplit < 1,
    "button face split must be between 0 and 1"
  )
  local contentInsetX = metric(spec.contentInsetX, "button horizontal content inset")
  local contentInsetY = metric(spec.contentInsetY, "button vertical content inset")

  local border = shape(rect, cornerCut, "button border")
  local rimRect = insetRect(rect, borderWidth)
  local rim = shape(rimRect, math.max(0, cornerCut - borderWidth), "button rim")
  local innerBorderRect = insetRect(rimRect, rimWidth)
  local innerBorder = shape(innerBorderRect, math.max(0, cornerCut - borderWidth - rimWidth), "button inner border")
  local faceRect = insetRect(innerBorderRect, innerBorderWidth)
  local face = shape(faceRect, math.max(0, cornerCut - borderWidth - rimWidth - innerBorderWidth), "button face")

  local contentRect = {
    x = faceRect.x + contentInsetX,
    y = faceRect.y + contentInsetY,
    width = faceRect.width - contentInsetX * 2,
    height = faceRect.height - contentInsetY * 2,
  }
  assertPositiveRectangle(contentRect, "button content rectangle")
  assertFiniteRectangle(contentRect, "button content rectangle")

  face.splitY = faceRect.y + faceRect.height * spec.faceSplit

  return {
    rect = rect,
    border = border,
    rim = rim,
    innerBorder = innerBorder,
    face = face,
    contentRect = contentRect,
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
