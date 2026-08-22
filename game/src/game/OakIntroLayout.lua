-- Responsive geometry for Oak/profile presentation. Every pointer region is
-- derived here and consumed by both the renderer and the input adapter.

local OakIntroLayout = {}

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

---@param width number
---@param height number
---@param view table
---@param glyphs string[]
---@return table
function OakIntroLayout.compute(width, height, view, glyphs)
  assert(type(width) == "number" and width > 0 and type(height) == "number" and height > 0, "Oak viewport is invalid")
  assert(type(view) == "table" and type(glyphs) == "table", "Oak layout requires view and glyphs")
  local margin = math.max(12, math.floor(math.min(width, height) * 0.06))
  local contentWidth = width - margin * 2
  local cardWidth = math.min(220, math.floor((contentWidth - 16) / 2))
  local cardHeight = math.min(150, math.max(96, math.floor(height * 0.27)))
  local left = math.floor((width - cardWidth * 2 - 16) / 2)
  local cardY = math.floor(height * 0.2)
  local cards = {
    [0] = rect(left, cardY, cardWidth, cardHeight),
    [1] = rect(left + cardWidth + 16, cardY, cardWidth, cardHeight),
  }
  local grid = {}
  local columns = math.max(1, math.min(8, view.virtualKeyColumns or math.floor(contentWidth / 42)))
  local cell = math.floor(contentWidth / columns)
  local gridY = math.floor(height * 0.42)
  local keys = view.virtualKeys or {}
  for index, key in ipairs(keys) do
    local zero = index - 1
    local column = zero % columns
    local row = math.floor(zero / columns)
    grid[index] = {
      rect = rect(margin + column * cell, gridY + row * 34, cell - 4, 30),
      kind = key.kind,
      glyph = key.glyph,
    }
  end
  return {
    viewport = rect(0, 0, width, height),
    message = rect(margin, height - margin - 112, contentWidth, 96),
    cards = cards,
    nameGrid = grid,
    virtualKeyColumns = columns,
    genderFocus = view.genderFocus,
  }
end

---@param region table
---@param x number
---@param y number
---@return boolean
function OakIntroLayout.contains(region, x, y)
  return region ~= nil
    and x >= region.x
    and y >= region.y
    and x < region.x + region.width
    and y < region.y + region.height
end

return OakIntroLayout
