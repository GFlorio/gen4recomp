-- Pure responsive Main Menu geometry. The same card rectangles are returned
-- for drawing and pointer/touch hit testing.

local MainMenuLayout = {}

local MARGIN = 16
local HEADER_HEIGHT = 32
local CARD_HEIGHT = 44
local CARD_GAP = 8
local DELETE_WIDTH = 48
local DELETE_GAP = 8

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

---@param rect table
---@param x number
---@param y number
---@return boolean
function MainMenuLayout.contains(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

---@param items table[]
---@param focusedIndex integer
---@param width number
---@param height number
---@param previousOffset number
---@param dialog table|nil
---@return table
function MainMenuLayout.compute(items, focusedIndex, width, height, previousOffset, dialog)
  assert(type(items) == "table" and #items > 0, "Main Menu layout needs items")
  assert(type(width) == "number" and type(height) == "number", "Main Menu layout needs viewport dimensions")
  local viewport = { x = 0, y = 0, width = math.max(1, width), height = math.max(1, height) }
  local contentX = MARGIN
  local contentY = MARGIN + HEADER_HEIGHT
  local contentWidth = math.max(1, width - MARGIN * 2)
  local contentHeight = math.max(1, height - MARGIN * 2 - HEADER_HEIGHT)
  local cardsHeight = #items * CARD_HEIGHT + (#items - 1) * CARD_GAP
  local maxOffset = math.max(0, cardsHeight - contentHeight)
  local offset = clamp(previousOffset or 0, 0, maxOffset)
  local focusedTop = (focusedIndex - 1) * (CARD_HEIGHT + CARD_GAP)
  local focusedBottom = focusedTop + CARD_HEIGHT
  if focusedTop < offset then
    offset = focusedTop
  elseif focusedBottom > offset + viewport.height then
    offset = focusedBottom - viewport.height
  end
  offset = clamp(offset, 0, maxOffset)

  local cards = {}
  for index, item in ipairs(items) do
    local y = contentY + (index - 1) * (CARD_HEIGHT + CARD_GAP) - offset
    local fullWidth = contentWidth
    local bodyWidth = fullWidth
    local delete = nil
    if item.canDelete then
      bodyWidth = math.max(1, fullWidth - DELETE_WIDTH - DELETE_GAP)
      delete = { x = contentX + bodyWidth + DELETE_GAP, y = y, width = DELETE_WIDTH, height = CARD_HEIGHT }
    end
    cards[item.id] = {
      body = { x = contentX, y = y, width = bodyWidth, height = CARD_HEIGHT },
      delete = delete,
    }
  end

  local result = {
    viewport = viewport,
    cards = cards,
    offset = offset,
    contentHeight = cardsHeight,
  }
  if dialog then
    local boxWidth = math.max(1, math.min(420, width - MARGIN * 2))
    local boxHeight = 136
    local box = {
      x = math.floor((width - boxWidth) / 2),
      y = math.floor((height - boxHeight) / 2),
      width = boxWidth,
      height = math.min(boxHeight, math.max(1, height)),
    }
    local actionWidth = math.max(1, math.floor((box.width - 3 * DELETE_GAP) / 2))
    result.dialog = {
      box = box,
      cancel = { x = box.x + DELETE_GAP, y = box.y + box.height - 52, width = actionWidth, height = 36 },
      delete = {
        x = box.x + 2 * DELETE_GAP + actionWidth,
        y = box.y + box.height - 52,
        width = actionWidth,
        height = 36,
      },
    }
  end
  return result
end

return MainMenuLayout
