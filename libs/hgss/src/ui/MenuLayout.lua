-- MenuLayout deterministically resolves menu geometry from a ScreenTopology.
-- It is deliberately pure: text measurement, rendering, and input dispatch
-- remain outside this module.

---@class MenuLayout
---@type { BOTTOM_SCREEN_TILE_PLACEMENT: string }
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local MenuLayout = {}

MenuLayout.minimumTouchTarget = 44

local TILE_COLUMNS = 31
local TILE_ROWS = 23
local BASE_ROW_HEIGHT = 20
local BASE_PADDING = 8
local BASE_GUTTER = 12
local BASE_MARGIN = 4
local BASE_CANCEL_GAP = 4
local PORTRAIT_SAFE_ASPECT_MAX = 0.8
local WIDE_SAFE_ASPECT_MIN = 1.6
local LARGE_MENU_ITEM_COUNT = 8
local MAX_FLOATING_SAFE_HEIGHT = 0.65

local MODES = { auto = true, floating = true, docked = true }
local ANCHORS = {
  auto = true,
  top_left = true,
  top_right = true,
  bottom_left = true,
  bottom_right = true,
  bottom = true,
  side = true,
}
local SURFACES = { auto = true, main = true, auxiliary = true }

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function assertRectangle(rectangle, name)
  assert(type(rectangle) == "table", name .. " must be a rectangle")
  assert(isFiniteNumber(rectangle.x), name .. ".x must be finite")
  assert(isFiniteNumber(rectangle.y), name .. ".y must be finite")
  assert(isFiniteNumber(rectangle.width) and rectangle.width > 0, name .. ".width must be positive and finite")
  assert(isFiniteNumber(rectangle.height) and rectangle.height > 0, name .. ".height must be positive and finite")
end

local function copyRectangle(rectangle)
  return { x = rectangle.x, y = rectangle.y, width = rectangle.width, height = rectangle.height }
end

local function overlaps(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(value, maximum))
end

local function inset(rectangle, amount)
  assert(rectangle.width > amount * 2 and rectangle.height > amount * 2, "safe region is too small for menu margins")
  return {
    x = rectangle.x + amount,
    y = rectangle.y + amount,
    width = rectangle.width - amount * 2,
    height = rectangle.height - amount * 2,
  }
end

local function assertItems(menu)
  assert(type(menu) == "table", "menu layout requires a menu")
  assert(type(menu.items) == "table" and #menu.items > 0, "menu layout requires at least one item")
  for index = 1, #menu.items do
    assert(type(menu.items[index]) == "table", "menu item must be a table")
  end
  local selectedIndex = menu.selectedIndex or 0
  assert(type(selectedIndex) == "number" and selectedIndex % 1 == 0, "menu selected index must be an integer")
  assert(selectedIndex >= 0 and selectedIndex < #menu.items, "menu selected index is out of range")
  assert(menu.cancellable == nil or type(menu.cancellable) == "boolean", "menu cancellable must be a boolean")
  return selectedIndex
end

local function placement(preference)
  preference = preference or {}
  assert(type(preference) == "table", "placement preference must be a table")
  local mode = preference.mode or "auto"
  local anchor = preference.anchor or "auto"
  local surface = preference.surface or "auto"
  assert(MODES[mode], "menu placement mode is invalid")
  assert(ANCHORS[anchor], "menu placement anchor is invalid")
  assert(SURFACES[surface], "menu placement surface is invalid")
  return mode, anchor, surface
end

local function selectSurface(topology, requested)
  assert(
    type(topology) == "table" and type(topology.surfaces) == "table" and #topology.surfaces > 0,
    "menu layout requires a ScreenTopology"
  )
  local selected
  if requested == "auxiliary" then
    for _, surface in ipairs(topology.surfaces) do
      if surface.role == "auxiliary" then
        selected = surface
        break
      end
    end
    assert(selected, "menu placement requests an unavailable auxiliary surface")
  elseif requested == "main" then
    for _, surface in ipairs(topology.surfaces) do
      if surface.role == "world" then
        selected = surface
        break
      end
    end
    assert(selected, "menu placement requests an unavailable main surface")
  else
    for _, surface in ipairs(topology.surfaces) do
      if surface.role == "auxiliary" then
        selected = surface
        break
      end
    end
    selected = selected or topology.surfaces[1]
  end
  assertRectangle(selected.safeRect, "selected surface safeRect")
  return selected
end

local function itemText(item)
  if type(item.label) == "string" then
    return item.label
  end
  if type(item.text) == "string" then
    return item.text
  end
  if type(item.text) == "table" and type(item.text.text) == "string" then
    return item.text.text
  end
  return ""
end

local function intrinsicWidth(menu, measureText, scale, maximum)
  local longest = 0
  for _, item in ipairs(menu.items) do
    local measured = measureText(itemText(item))
    assert(isFiniteNumber(measured) and measured >= 0, "menu text measurement must return a finite non-negative number")
    longest = math.max(longest, measured)
  end
  local target = (longest + BASE_PADDING * 2 + BASE_GUTTER) * scale
  return math.min(maximum, math.max(96 * scale, target))
end

local function occupiedFor(spec, surface)
  local regions = {}
  for _, region in ipairs(surface.occupiedRegions or {}) do
    regions[#regions + 1] = region
  end
  if spec.occupiedRegions == nil then
    return regions
  end
  assert(type(spec.occupiedRegions) == "table", "occupied regions must be an array")
  for index, region in ipairs(spec.occupiedRegions) do
    assertRectangle(region, "occupiedRegions[" .. index .. "]")
    regions[#regions + 1] = region
  end
  return regions
end

local function hasCollision(frame, regions)
  for _, region in ipairs(regions) do
    if overlaps(frame, region) then
      return true
    end
  end
  return false
end

local function sourceAnchor(sourcePlacement, bounds, frame)
  if sourcePlacement == nil then
    return bounds.x + (bounds.width - frame.width) / 2, bounds.y + (bounds.height - frame.height) / 2
  end
  assert(type(sourcePlacement) == "table", "source placement must be a table")
  assert(sourcePlacement.system == MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT, "source placement system is invalid")
  assert(
    isFiniteNumber(sourcePlacement.x) and isFiniteNumber(sourcePlacement.y),
    "source placement coordinates must be finite"
  )
  assert(sourcePlacement.x >= 0 and sourcePlacement.x < TILE_COLUMNS, "source placement x is out of range")
  assert(sourcePlacement.y >= 0 and sourcePlacement.y < TILE_ROWS, "source placement y is out of range")
  local x = bounds.x + sourcePlacement.x / TILE_COLUMNS * (bounds.width - frame.width)
  local y = bounds.y + sourcePlacement.y / TILE_ROWS * (bounds.height - frame.height)
  return x, y
end

local function anchoredPosition(anchor, bounds, frame)
  local right = bounds.x + bounds.width - frame.width
  local bottom = bounds.y + bounds.height - frame.height
  if anchor == "top_left" then
    return bounds.x, bounds.y
  end
  if anchor == "top_right" then
    return right, bounds.y
  end
  if anchor == "bottom_left" then
    return bounds.x, bottom
  end
  if anchor == "bottom_right" then
    return right, bottom
  end
  if anchor == "bottom" then
    return bounds.x + (bounds.width - frame.width) / 2, bottom
  end
  if anchor == "side" then
    return right, bounds.y + (bounds.height - frame.height) / 2
  end
  return bounds.x + (bounds.width - frame.width) / 2, bounds.y + (bounds.height - frame.height) / 2
end

local function floatingFrame(bounds, width, height, sourcePlacement, anchor, regions)
  local frame = { x = bounds.x, y = bounds.y, width = width, height = height }
  local x, y
  if anchor == "auto" then
    x, y = sourceAnchor(sourcePlacement, bounds, frame)
  else
    x, y = anchoredPosition(anchor, bounds, frame)
  end
  local candidates = {
    { x = x, y = y },
    { x = bounds.x + bounds.width - width - (x - bounds.x), y = y },
    { x = x, y = bounds.y + bounds.height - height - (y - bounds.y) },
    { x = bounds.x + bounds.width - width - (x - bounds.x), y = bounds.y + bounds.height - height - (y - bounds.y) },
  }
  for _, candidate in ipairs(candidates) do
    frame.x = clamp(candidate.x, bounds.x, bounds.x + bounds.width - width)
    frame.y = clamp(candidate.y, bounds.y, bounds.y + bounds.height - height)
    if not hasCollision(frame, regions) then
      return copyRectangle(frame)
    end
  end
  return nil
end

local function autoPresentation(surface, menu, mode)
  if mode ~= "auto" then
    return mode
  end
  if surface.role == "auxiliary" then
    return "docked"
  end
  local ratio = surface.safeRect.width / surface.safeRect.height
  if ratio < PORTRAIT_SAFE_ASPECT_MAX then
    return "docked"
  end
  if ratio >= WIDE_SAFE_ASPECT_MIN and #menu.items >= LARGE_MENU_ITEM_COUNT then
    return "docked"
  end
  return "floating"
end

---@param frame ScreenTopology.Rectangle
---@param menu { items: table[], selectedIndex?: integer, cancellable?: boolean }
---@param rowHeight number
---@param padding number
---@param cancelHeight number
---@return ScreenTopology.Rectangle, ScreenTopology.Rectangle[], number, number
local function layoutItems(frame, menu, rowHeight, padding, cancelHeight)
  local content = {
    x = frame.x + padding,
    y = frame.y + padding,
    width = frame.width - padding * 2,
    height = frame.height - padding * 2 - cancelHeight,
  }
  local totalHeight = #menu.items * rowHeight
  local maxOffset = math.max(0, totalHeight - content.height)
  local selectedTop = (menu.selectedIndex or 0) * rowHeight
  local offset = clamp(selectedTop - (content.height - rowHeight), 0, maxOffset)
  local itemRects = {}
  for luaIndex = 1, #menu.items do
    itemRects[luaIndex - 1] = {
      x = content.x,
      y = content.y + (luaIndex - 1) * rowHeight - offset,
      width = content.width,
      height = rowHeight,
    }
  end
  return content, itemRects, offset, maxOffset
end

local DIRECTIONS = { up = true, down = true, left = true, right = true }

-- Finds the item most aligned with the current row or column in a cardinal
-- direction. Cross-axis alignment wins over distance, preserving grid-like
-- navigation when physical dimensions change.
---@param layout { itemCount: integer, itemRects: ScreenTopology.Rectangle[] }
---@param itemIndex integer
---@param direction "up"|"down"|"left"|"right"
---@return integer?
function MenuLayout.adjacentItem(layout, itemIndex, direction)
  assert(type(layout) == "table", "menu layout is required")
  assert(
    type(layout.itemCount) == "number" and layout.itemCount % 1 == 0 and layout.itemCount > 0,
    "menu layout item count is invalid"
  )
  assert(type(layout.itemRects) == "table", "menu layout item rectangles are required")
  assert(
    type(itemIndex) == "number" and itemIndex % 1 == 0 and itemIndex >= 0 and itemIndex < layout.itemCount,
    "menu item index is out of range"
  )
  assert(DIRECTIONS[direction], "menu navigation direction is invalid")

  local current = assert(layout.itemRects[itemIndex], "menu layout item rectangle is missing")
  assertRectangle(current, "menu layout item rectangle")
  local currentX = current.x + current.width / 2
  local currentY = current.y + current.height / 2
  local adjacentIndex
  local nearestOffset
  local nearestDistance
  for candidateIndex = 0, layout.itemCount - 1 do
    if candidateIndex ~= itemIndex then
      local candidate = assert(layout.itemRects[candidateIndex], "menu layout item rectangle is missing")
      assertRectangle(candidate, "menu layout item rectangle")
      local dx = candidate.x + candidate.width / 2 - currentX
      local dy = candidate.y + candidate.height / 2 - currentY
      local distance, offset
      if direction == "up" and dy < 0 then
        distance, offset = -dy, math.abs(dx)
      elseif direction == "down" and dy > 0 then
        distance, offset = dy, math.abs(dx)
      elseif direction == "left" and dx < 0 then
        distance, offset = -dx, math.abs(dy)
      elseif direction == "right" and dx > 0 then
        distance, offset = dx, math.abs(dy)
      end
      if
        distance
        and (
          nearestDistance == nil
          or offset < nearestOffset
          or (offset == nearestOffset and distance < nearestDistance)
        )
      then
        adjacentIndex = candidateIndex
        nearestOffset = offset
        nearestDistance = distance
      end
    end
  end
  return adjacentIndex
end

---@class MenuLayout.Spec
---@field topology ScreenTopology
---@field menu { items: table[], selectedIndex?: integer, cancellable?: boolean }
---@field sourcePlacement? { system: "hgss_bottom_screen_tiles", x: number, y: number }
---@field placementPreference? { mode?: "auto"|"floating"|"docked", anchor?: string, surface?: string }
---@field occupiedRegions? ScreenTopology.Rectangle[]
---@field uiScale? number
---@field measureText fun(text: string): number

-- Resolves immutable menu geometry in physical surface coordinates. itemRects
-- use zero-based menu indexes and contain every item; rows outside scrollViewport are clipped by
-- the renderer, while the selected row is always brought into view.

---@param spec MenuLayout.Spec
---@return { surface: ScreenTopology.Surface, presentation: "floating"|"docked", frame: ScreenTopology.Rectangle, contentRect: ScreenTopology.Rectangle, itemCount: integer, itemRects: ScreenTopology.Rectangle[], itemTexts: table<integer, string>, scrollViewport: ScreenTopology.Rectangle, cancelRect: ScreenTopology.Rectangle?, selectedIndex: integer, scrollOffset: number, maxScrollOffset: number }
function MenuLayout.resolve(spec)
  assert(type(spec) == "table", "menu layout requires a specification")
  local selectedIndex = assertItems(spec.menu)
  local scale = spec.uiScale or 1
  assert(isFiniteNumber(scale) and scale > 0, "menu ui scale must be positive and finite")
  local mode, anchor, requestedSurface = placement(spec.placementPreference)
  local surface = selectSurface(spec.topology, requestedSurface)
  local bounds = inset(surface.safeRect, BASE_MARGIN * scale)
  local touch = surface.touch
  local rowHeight = math.max(BASE_ROW_HEIGHT * scale, touch and MenuLayout.minimumTouchTarget * scale or 0)
  local measureText = spec.measureText
  assert(type(measureText) == "function", "menu text measurement must be a function")
  local width = intrinsicWidth(spec.menu, measureText, scale, bounds.width)
  local padding = BASE_PADDING * scale
  local cancelHeight = spec.menu.cancellable == true
      and touch
      and (MenuLayout.minimumTouchTarget + BASE_CANCEL_GAP) * scale
    or 0
  assert(bounds.width > padding * 2, "safe region is too narrow for menu content")
  assert(bounds.height >= rowHeight + padding * 2 + cancelHeight, "safe region is too short for one menu row")
  local maximumHeight = math.max(rowHeight + padding * 2 + cancelHeight, bounds.height * MAX_FLOATING_SAFE_HEIGHT)
  local naturalHeight = #spec.menu.items * rowHeight + padding * 2 + cancelHeight
  local height = math.min(naturalHeight, maximumHeight, bounds.height)
  local presentation = autoPresentation(surface, spec.menu, mode)
  local regions = occupiedFor(spec, surface)
  local frame
  if presentation == "floating" then
    frame = floatingFrame(bounds, width, height, spec.sourcePlacement, anchor, regions)
    if not frame then
      presentation = "docked"
    end
  end
  if presentation == "docked" then
    width = bounds.width
    height = math.min(naturalHeight, bounds.height)
    frame = {
      x = bounds.x,
      y = bounds.y + bounds.height - height,
      width = width,
      height = height,
    }
  end
  local resolvedFrame = assert(frame, "menu layout did not resolve a frame")
  local resolvedMenu = {
    items = spec.menu.items,
    selectedIndex = selectedIndex,
    cancellable = spec.menu.cancellable == true,
  }
  local contentRect, itemRects, scrollOffset, maxScrollOffset =
    layoutItems(resolvedFrame, resolvedMenu, rowHeight, padding, cancelHeight)
  local itemTexts = {}
  for luaIndex = 1, #spec.menu.items do
    itemTexts[luaIndex - 1] = itemText(spec.menu.items[luaIndex])
  end
  local cancelRect
  if cancelHeight > 0 then
    cancelRect = {
      x = contentRect.x,
      y = contentRect.y + contentRect.height + BASE_CANCEL_GAP * scale,
      width = contentRect.width,
      height = MenuLayout.minimumTouchTarget * scale,
    }
  end
  return {
    surface = surface,
    presentation = presentation,
    frame = resolvedFrame,
    contentRect = contentRect,
    itemCount = #spec.menu.items,
    itemRects = itemRects,
    itemTexts = itemTexts,
    scrollViewport = copyRectangle(contentRect),
    cancelRect = cancelRect,
    selectedIndex = selectedIndex,
    scrollOffset = scrollOffset,
    maxScrollOffset = maxScrollOffset,
  }
end

return MenuLayout
