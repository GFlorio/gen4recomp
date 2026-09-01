-- Immediate-mode LÖVE painter for layered button geometry.

local ButtonPainter = {}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function color(palette, name)
  local value = palette[name]
  assert(type(value) == "table", "button palette role is required: " .. name)
  assert(#value == 3 or #value == 4, "button palette role must have three or four components: " .. name)
  for index = 1, #value do
    assert(finite(value[index]), "button palette role must contain finite numbers: " .. name)
  end
  return value[1], value[2], value[3], value[4] or 1
end

local function setColor(graphics, value)
  graphics.setColor(value[1], value[2], value[3], value[4])
end

local function drawCutShape(graphics, descriptor)
  local rect = descriptor.rect
  local cut = descriptor.cornerCut
  if cut == 0 then
    graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
    return
  end
  graphics.polygon(
    "fill",
    rect.x + cut,
    rect.y,
    rect.x + rect.width - cut,
    rect.y,
    rect.x + rect.width,
    rect.y + cut,
    rect.x + rect.width,
    rect.y + rect.height - cut,
    rect.x + rect.width - cut,
    rect.y + rect.height,
    rect.x + cut,
    rect.y + rect.height,
    rect.x,
    rect.y + rect.height - cut,
    rect.x,
    rect.y + cut
  )
end

local function drawFaceTop(graphics, face)
  local rect = face.rect
  local splitY = face.splitY
  local cut = face.cornerCut
  if cut == 0 then
    graphics.rectangle("fill", rect.x, rect.y, rect.width, splitY - rect.y)
    return
  end

  local splitOffset = splitY - rect.y
  local leftAtSplit = rect.x + math.max(0, cut - splitOffset)
  local rightAtSplit = rect.x + rect.width - math.max(0, cut - splitOffset)
  graphics.polygon(
    "fill",
    rect.x + cut,
    rect.y,
    rect.x + rect.width - cut,
    rect.y,
    rightAtSplit,
    splitY,
    leftAtSplit,
    splitY
  )
end

---@param graphics table
---@param button table
---@param palette table
function ButtonPainter.draw(graphics, button, palette)
  assert(type(graphics) == "table", "button graphics is required")
  assert(type(graphics.setColor) == "function", "button graphics setColor is required")
  assert(type(graphics.rectangle) == "function", "button graphics rectangle is required")
  assert(type(graphics.polygon) == "function", "button graphics polygon is required")
  assert(type(button) == "table", "resolved button is required")
  assert(type(palette) == "table", "button palette is required")

  local border = { color(palette, "border") }
  local rim = { color(palette, "rim") }
  local innerBorder = { color(palette, "innerBorder") }
  local faceTop = { color(palette, "faceTop") }
  local faceBottom = { color(palette, "faceBottom") }

  setColor(graphics, border)
  drawCutShape(graphics, button.border)
  setColor(graphics, rim)
  drawCutShape(graphics, button.rim)
  setColor(graphics, innerBorder)
  drawCutShape(graphics, button.innerBorder)
  setColor(graphics, faceBottom)
  drawCutShape(graphics, button.face)
  setColor(graphics, faceTop)
  drawFaceTop(graphics, button.face)
end

return ButtonPainter
