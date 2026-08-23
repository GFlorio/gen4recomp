-- Pure host placement for the authentic 256 x 48 dialogue window. Local
-- geometry remains source-sized; only this record knows the host rectangle.

local Layout = {}

---@class DialoguePresentationLayout.Rect
---@field x number
---@field y number
---@field width number
---@field height number

---@class DialoguePresentationLayout.Presentation
---@field bounds DialoguePresentationLayout.Rect
---@field origin { x: number, y: number }
---@field scale number
---@field outerRect DialoguePresentationLayout.Rect
---@field box DialoguePresentationLayout.Rect
---@field text DialoguePresentationLayout.Rect
---@field cursor DialoguePresentationLayout.Rect
---@field lineHeight number

local WIDTH = 256
local HEIGHT = 48
local BOX = { x = 16, y = 8, width = 216, height = 32 }
local TEXT = { x = 26, y = 8, width = 196, height = 32 }
local CURSOR = { x = 202, y = 26, width = 10, height = 8 }
local LINE_HEIGHT = 16
local EPSILON = 1e-9

local function finitePositive(value, name)
  assert(
    type(value) == "number" and value > 0 and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be a finite positive number"
  )
end

local function finite(value, name)
  assert(
    type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be finite"
  )
end

local function validateBounds(bounds)
  assert(type(bounds) == "table", "dialogue presentation bounds must be a table")
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    finite(bounds[key], "dialogue presentation bounds." .. key)
  end
  finitePositive(bounds.width, "dialogue presentation bounds.width")
  finitePositive(bounds.height, "dialogue presentation bounds.height")
end

---@param bounds { x: number, y: number, width: number, height: number }
---@param options? { scale?: number, maxScale?: number }
---@return DialoguePresentationLayout.Presentation
function Layout.compute(bounds, options)
  validateBounds(bounds)
  options = options or {}
  assert(type(options) == "table", "dialogue presentation options must be a table")
  if options.scale ~= nil then
    finitePositive(options.scale, "dialogue presentation scale")
  end
  if options.maxScale ~= nil then
    finitePositive(options.maxScale, "dialogue presentation maxScale")
  end
  local scale = options.scale or math.min(bounds.width / WIDTH, bounds.height / HEIGHT, options.maxScale or math.huge)
  assert(scale > 0, "dialogue presentation does not fit its bounds")
  assert(
    WIDTH * scale <= bounds.width + EPSILON and HEIGHT * scale <= bounds.height + EPSILON,
    "dialogue presentation scale does not fit its bounds"
  )
  local origin = {
    x = bounds.x + (bounds.width - WIDTH * scale) / 2,
    y = bounds.y + bounds.height - HEIGHT * scale,
  }
  return {
    bounds = { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height },
    origin = origin,
    scale = scale,
    outerRect = { x = origin.x, y = origin.y, width = WIDTH * scale, height = HEIGHT * scale },
    box = { x = BOX.x, y = BOX.y, width = BOX.width, height = BOX.height },
    text = { x = TEXT.x, y = TEXT.y, width = TEXT.width, height = TEXT.height },
    cursor = { x = CURSOR.x, y = CURSOR.y, width = CURSOR.width, height = CURSOR.height },
    lineHeight = LINE_HEIGHT,
  }
end

---@param presentation DialoguePresentationLayout.Presentation
function Layout.validate(presentation)
  assert(type(presentation) == "table", "dialogue presentation must be a table")
  validateBounds(presentation.bounds)
  assert(
    type(presentation.origin) == "table"
      and type(presentation.origin.x) == "number"
      and type(presentation.origin.y) == "number",
    "dialogue presentation requires an origin"
  )
  finite(presentation.origin.x, "dialogue presentation origin.x")
  finite(presentation.origin.y, "dialogue presentation origin.y")
  finitePositive(presentation.scale, "dialogue presentation scale")
  assert(type(presentation.outerRect) == "table", "dialogue presentation requires an outer rectangle")
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    finite(presentation.outerRect[key], "dialogue presentation outerRect." .. key)
  end
  assert(
    presentation.outerRect.width > 0 and presentation.outerRect.height > 0,
    "dialogue presentation outer rectangle must be positive"
  )
  assert(
    math.abs(presentation.outerRect.x - presentation.origin.x) <= EPSILON
      and math.abs(presentation.outerRect.y - presentation.origin.y) <= EPSILON
      and math.abs(presentation.outerRect.width - WIDTH * presentation.scale) <= EPSILON
      and math.abs(presentation.outerRect.height - HEIGHT * presentation.scale) <= EPSILON,
    "dialogue presentation has inconsistent outer rectangle"
  )
  local function requireRect(rect, expected, name)
    assert(type(rect) == "table", "dialogue presentation requires " .. name)
    for _, key in ipairs({ "x", "y", "width", "height" }) do
      finite(rect[key], "dialogue presentation " .. name .. "." .. key)
    end
    for _, key in ipairs({ "x", "y", "width", "height" }) do
      assert(rect[key] == expected[key], "dialogue presentation has invalid " .. name)
    end
  end
  requireRect(presentation.box, BOX, "box")
  requireRect(presentation.text, TEXT, "text box")
  requireRect(presentation.cursor, CURSOR, "cursor")
  assert(presentation.lineHeight == LINE_HEIGHT, "dialogue presentation has invalid line height")
end

return Layout
