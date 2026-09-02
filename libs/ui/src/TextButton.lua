-- Yes/No-style text button composing the generic Button geometry.

local Button = require("libs.ui.src.Button")

---@class TextAdapter
---@field measure fun(label:string):number
---@field lineHeight number
---@field draw fun(label:string, x:number, y:number)

local TextButton = {}

TextButton.REFERENCE_WIDTH = 120
TextButton.REFERENCE_HEIGHT = 56

local DEFAULT_COLORS = {
  border = { 66 / 255, 66 / 255, 66 / 255, 1 },
  rim = { 230 / 255, 230 / 255, 222 / 255, 1 },
  innerBorder = { 25 / 255, 189 / 255, 197 / 255, 1 },
  faceTop = { 49 / 255, 222 / 255, 230 / 255, 1 },
  faceBottom = { 8 / 255, 156 / 255, 165 / 255, 1 },
  focusOuter = { 1, 1, 1, 1 },
  focusInner = { 1, 0, 0, 1 },
}

local ALLOWED_COLOR_KEYS = {
  border = true,
  rim = true,
  innerBorder = true,
  faceTop = true,
  faceBottom = true,
  focusOuter = true,
  focusInner = true,
}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function assertFinitePositiveScale(value)
  assert(finite(value) and value > 0, "text button scale must be a finite positive number")
end

local function copyColor(value)
  local result = {}
  for index = 1, #value do
    result[index] = value[index]
  end
  return result
end

local function mergeColors(overrides)
  local result = {}
  for key, value in pairs(DEFAULT_COLORS) do
    result[key] = copyColor(value)
  end
  if overrides ~= nil then
    assert(type(overrides) == "table", "text button colors must be a table")
    for key, value in pairs(overrides) do
      assert(ALLOWED_COLOR_KEYS[key], "text button unknown color role: " .. tostring(key))
      assert(type(value) == "table", "text button color role must be a table: " .. tostring(key))
      assert(#value == 3 or #value == 4, "text button color role must have three or four components: " .. tostring(key))
      for index = 1, #value do
        assert(finite(value[index]), "text button color must be finite: " .. tostring(key))
      end
      local copy = {}
      for index = 1, #value do
        copy[index] = value[index]
      end
      if #copy == 3 then
        copy[4] = 1
      end
      result[key] = copy
    end
  end
  return result
end

local function rectangle(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite numbers")
  end
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

---@param spec { rect: {x:number,y:number,width:number,height:number}, scale: number }
---@return table
function TextButton.resolve(spec)
  assert(type(spec) == "table", "text button specification is required")
  local rectValue = rectangle(spec.rect, "text button rectangle")
  assertFinitePositiveScale(spec.scale)
  local scale = spec.scale
  local resolved = Button.resolve({
    rect = rectValue,
    borderWidth = 2 * scale,
    rimWidth = 1 * scale,
    innerBorderWidth = 1 * scale,
    cornerCut = 2 * scale,
    cornerRadius = 3 * scale,
    faceSplit = 0.5,
    contentInsetX = 4 * scale,
    contentInsetY = 12 * scale,
  })
  resolved.scale = scale
  return resolved
end

local function drawFocusOutline(graphics, button, colors)
  local scale = assert(button.scale, "text button scale is missing")
  local whiteWidth = 5 * scale
  local redWidth = 3 * scale
  local outerRadius = 3 * scale
  local inset = 1 * scale
  local radius = math.max(0, outerRadius - whiteWidth / 2)
  graphics.setColor(colors.focusOuter[1], colors.focusOuter[2], colors.focusOuter[3], colors.focusOuter[4])
  graphics.setLineWidth(whiteWidth)
  graphics.rectangle(
    "line",
    button.rect.x + inset,
    button.rect.y + inset,
    button.rect.width - inset * 2,
    button.rect.height - inset * 2,
    radius,
    radius
  )
  graphics.setColor(colors.focusInner[1], colors.focusInner[2], colors.focusInner[3], colors.focusInner[4])
  graphics.setLineWidth(redWidth)
  graphics.rectangle(
    "line",
    button.rect.x + inset,
    button.rect.y + inset,
    button.rect.width - inset * 2,
    button.rect.height - inset * 2,
    radius,
    radius
  )
end

---@param graphics table
---@param button table
---@param spec { label: string, selected: boolean, text: TextAdapter, colors?: table }
function TextButton.draw(graphics, button, spec)
  assert(type(graphics) == "table", "text button graphics is required")
  assert(type(graphics.setColor) == "function", "text button graphics setColor is required")
  assert(type(graphics.rectangle) == "function", "text button graphics rectangle is required")
  assert(type(graphics.polygon) == "function", "text button graphics polygon is required")
  assert(type(button) == "table" and type(button.rect) == "table", "resolved text button is required")
  assert(type(spec) == "table", "text button spec is required")
  assert(type(spec.label) == "string", "text button label is required")
  assert(type(spec.selected) == "boolean", "text button selected flag is required")
  assert(type(spec.text) == "table", "text button text adapter is required")
  assert(type(spec.text.measure) == "function", "text button text measure is required")
  assert(
    finite(spec.text.lineHeight) and spec.text.lineHeight > 0,
    "text button lineHeight must be a finite positive number"
  )
  assert(type(spec.text.draw) == "function", "text button text draw is required")
  if spec.colors ~= nil then
    assert(type(spec.colors) == "table", "text button colors must be a table")
  end

  local colors = mergeColors(spec.colors)

  local palette = {
    border = colors.border,
    rim = colors.rim,
    innerBorder = colors.innerBorder,
    faceTop = colors.faceTop,
    faceBottom = colors.faceBottom,
  }

  Button.draw(graphics, button, palette)

  if spec.selected then
    -- Preserve graphics line width state? We set widths for focus; caller may rely on it.
    -- Ensure focus drawing uses setLineWidth if available, else fallback.
    if type(graphics.setLineWidth) == "function" and type(graphics.push) == "function" then
      drawFocusOutline(graphics, button, colors)
    elseif type(graphics.setLineWidth) == "function" then
      drawFocusOutline(graphics, button, colors)
    else
      -- If no setLineWidth, still draw with default width.
      drawFocusOutline(graphics, button, colors)
    end
  end

  local labelWidth = spec.text.measure(spec.label)
  assert(finite(labelWidth) and labelWidth >= 0, "text button label width must be a finite non-negative number")
  local lineHeight = spec.text.lineHeight
  local content = button.contentRect
  assert(type(content) == "table", "text button content rectangle is missing")

  -- Spec requires failure when label cannot fit.
  assert(labelWidth <= content.width + 1e-6, "text button label does not fit inside content rectangle")
  assert(lineHeight <= content.height + 1e-6, "text button label height does not fit inside content rectangle")

  local scale = assert(button.scale, "text button scale is missing")
  -- Text adapter works in source space. Apply button-local translate + scale.
  local localContentX = (content.x - button.rect.x) / scale
  local localContentY = (content.y - button.rect.y) / scale
  local localContentWidth = content.width / scale
  local localContentHeight = content.height / scale

  local textXSource = localContentX + (localContentWidth - labelWidth) / 2
  local textYSource = localContentY + (localContentHeight - lineHeight) / 2

  local pushed = false
  if
    type(graphics.push) == "function"
    and type(graphics.pop) == "function"
    and type(graphics.translate) == "function"
    and type(graphics.scale) == "function"
  then
    graphics.push()
    pushed = true
    graphics.translate(button.rect.x, button.rect.y)
    graphics.scale(scale, scale)
  elseif
    type(graphics.push) == "function"
    and type(graphics.pop) == "function"
    and type(graphics.scale) == "function"
  then
    graphics.push()
    pushed = true
    graphics.scale(scale, scale)
    -- Adjust coordinates to absolute source when translate unavailable.
    textXSource = content.x / scale + (content.width / scale - labelWidth) / 2
    textYSource = content.y / scale + (content.height / scale - lineHeight) / 2
  end

  local ok, err = pcall(function()
    spec.text.draw(spec.label, textXSource, textYSource)
  end)

  if pushed and type(graphics.pop) == "function" then
    graphics.pop()
  end

  if not ok then
    error(err, 0)
  end
end

return TextButton
