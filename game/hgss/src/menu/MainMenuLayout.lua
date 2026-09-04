-- Pure responsive Main Menu geometry. The same card rectangles are returned
-- for drawing and pointer/touch hit testing.

local MainMenuLayout = {}

local MARGIN = 16
local HEADER_HEIGHT = 32
local CARD_HEIGHT = 44
local CARD_GAP = 8
local MAX_CONTENT_WIDTH = 960
local CATALOG_ERROR_HEIGHT = 24
local DELETE_WIDTH = 48
local DELETE_GAP = 8

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

---@param rect table<string, unknown>
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
---@param dialog table<string, unknown>|nil
---@param hasCatalogError boolean|nil
---@return table<string, unknown>
function MainMenuLayout.compute(items, focusedIndex, width, height, previousOffset, dialog, hasCatalogError)
  assert(type(items) == "table" and #items > 0, "Main Menu layout needs items")
  assert(
    type(width) == "number" and width > 0 and type(height) == "number" and height > 0,
    "Main Menu layout needs positive viewport dimensions"
  )
  assert(hasCatalogError == nil or type(hasCatalogError) == "boolean", "catalog error presence must be boolean")
  local viewport = { x = 0, y = 0, width = math.max(1, width), height = math.max(1, height) }
  local availableWidth = math.max(0, width - MARGIN * 2)
  local contentWidth = math.max(1, math.min(availableWidth, MAX_CONTENT_WIDTH))
  local contentX = math.floor((width - contentWidth) / 2)
  local contentY = MARGIN + HEADER_HEIGHT
  local content = {
    x = contentX,
    y = contentY,
    width = contentWidth,
    height = math.max(1, height - MARGIN * 2 - HEADER_HEIGHT),
  }
  local totalCardsHeight = #items * CARD_HEIGHT + (#items - 1) * CARD_GAP
  local errorHeight = hasCatalogError and CATALOG_ERROR_HEIGHT or 0
  local errorGap = hasCatalogError and CARD_GAP or 0
  local totalContentHeight = totalCardsHeight + errorHeight + errorGap
  local maxOffset = math.max(0, totalContentHeight - content.height)
  local offset = clamp(previousOffset or 0, 0, maxOffset)
  local focusedTop = errorHeight + errorGap + (focusedIndex - 1) * (CARD_HEIGHT + CARD_GAP)
  local focusedBottom = focusedTop + CARD_HEIGHT
  if CARD_HEIGHT <= content.height then
    if focusedTop < offset then
      offset = focusedTop
    elseif focusedBottom > offset + content.height then
      offset = focusedBottom - content.height
    end
  end
  offset = clamp(offset, 0, maxOffset)

  local cards = {}
  local cardsStartY = content.y + errorHeight + errorGap
  for index, item in ipairs(items) do
    local y = cardsStartY + (index - 1) * (CARD_HEIGHT + CARD_GAP) - offset
    local fullWidth = content.width
    local bodyWidth = fullWidth
    local delete = nil
    if item.canDelete then
      bodyWidth = math.max(1, fullWidth - DELETE_WIDTH - DELETE_GAP)
      delete = { x = content.x + bodyWidth + DELETE_GAP, y = y, width = DELETE_WIDTH, height = CARD_HEIGHT }
    end
    cards[item.id] = {
      body = { x = content.x, y = y, width = bodyWidth, height = CARD_HEIGHT },
      delete = delete,
    }
  end

  local result = {
    viewport = viewport,
    content = content,
    cards = cards,
    offset = offset,
    totalCardsHeight = totalCardsHeight,
    totalContentHeight = totalContentHeight,
  }
  if hasCatalogError then
    result.catalogErrorRect = {
      x = content.x,
      y = content.y - offset,
      width = content.width,
      height = CATALOG_ERROR_HEIGHT,
    }
  end
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
