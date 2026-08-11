-- FieldMenuHost owns the live field-menu presentation snapshot. It translates
-- physical UI events through the current layout without giving layout or draw
-- code any authority over script results.

local MenuLayout = require("libs.engine.src.MenuLayout")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

---@class FieldMenuHost.Active
---@field definition FieldMenuController.Spec
---@field selectedIndex integer
---@field layout table?
---@field closingAtTick integer?

---@class FieldMenuHost
---@field private _input FieldInput
---@field private _topology ScreenTopology
---@field private _topologyFollowsViewport boolean
---@field private _measureText fun(text: string): number
---@field private _uiScale number
---@field private _active FieldMenuHost.Active?
local FieldMenuHost = {}
FieldMenuHost.__index = FieldMenuHost

local function contains(rect, x, y)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

local function itemAt(layout, x, y)
  if not contains(layout.scrollViewport, x, y) then
    return nil
  end
  for itemIndex = 0, layout.itemCount - 1 do
    local rect = layout.itemRects[itemIndex]
    if contains(rect, x, y) then
      return itemIndex
    end
  end
  return nil
end

---@param width number
---@param height number
---@return ScreenTopology
local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
end

---@param opts { width: number, height: number, input: FieldInput, screenTopology?: ScreenTopology, measureText: fun(text: string): number, uiScale?: number }
---@return FieldMenuHost
function FieldMenuHost.new(opts)
  assert(type(opts) == "table" and opts.input, "field menu host requires input")
  assert(type(opts.width) == "number" and opts.width > 0, "field menu host requires positive width")
  assert(type(opts.height) == "number" and opts.height > 0, "field menu host requires positive height")
  assert(type(opts.measureText) == "function", "field menu host requires presentation text measurement")
  local uiScale = opts.uiScale or 1
  assert(type(uiScale) == "number" and uiScale > 0, "field menu host ui scale must be positive")
  if opts.screenTopology ~= nil then
    assert(
      type(opts.screenTopology) == "table" and type(opts.screenTopology.surfaces) == "table",
      "field menu topology is invalid"
    )
  end
  return setmetatable({
    _input = opts.input,
    _topology = opts.screenTopology or topology(opts.width, opts.height),
    _topologyFollowsViewport = opts.screenTopology == nil,
    _measureText = opts.measureText,
    _uiScale = uiScale,
    _active = nil,
  }, FieldMenuHost)
end

function FieldMenuHost:resize(width, height)
  assert(type(width) == "number" and width > 0, "field menu width must be positive")
  assert(type(height) == "number" and height > 0, "field menu height must be positive")
  if self._topologyFollowsViewport then
    self._topology = topology(width, height)
  end
  if self._active then
    self:_resolve(self._active.definition, self._active.selectedIndex)
  end
end

-- Replaces reconstructable presentation metrics and immediately rebuilds the
-- active geometry. Logical menu state remains owned by MenuTask.
---@param measureText fun(text: string): number
---@param uiScale number?
function FieldMenuHost:setPresentationMetrics(measureText, uiScale)
  assert(type(measureText) == "function", "field menu presentation requires text measurement")
  uiScale = uiScale or 1
  assert(type(uiScale) == "number" and uiScale > 0, "field menu ui scale must be positive")
  self._measureText = measureText
  self._uiScale = uiScale
  if self._active then
    self:_resolve(self._active.definition, self._active.selectedIndex)
  end
end

function FieldMenuHost:_resolve(definition, selectedIndex)
  local layout = MenuLayout.resolve({
    topology = self._topology,
    menu = {
      items = definition.items,
      selectedIndex = selectedIndex,
      cancellable = definition.cancellable,
    },
    sourcePlacement = definition.sourcePlacement,
    placementPreference = definition.placementPreference,
    uiScale = self._uiScale,
    measureText = self._measureText,
  })
  self._active.layout = layout
end

-- MenuTask calls sync after each controller step. The host acquires logical
-- UI focus exactly once and drops any edge that existed before that focus.
function FieldMenuHost:sync(state, tick)
  assert(type(state) == "table" and type(state.menuDefinition) == "table", "menu state is required")
  if self._active == nil then
    self._active = { definition = state.menuDefinition, selectedIndex = state.selectedIndex }
    self._input:beginUi(tick)
  end
  self._active.selectedIndex = state.selectedIndex
  self:_resolve(self._active.definition, state.selectedIndex)
end

function FieldMenuHost:close(tick)
  if self._active == nil then
    return
  end
  assert(type(tick) == "number" and tick == math.floor(tick), "menu close tick is required")
  self._active.closingAtTick = tick
  self._input:clearUi()
end

-- The scheduler publishes a completed task result on the following tick.
-- Keep the closing snapshot through that boundary so observing a closed menu
-- always also observes its result, without changing scheduler task timing.
function FieldMenuHost:advance(tick)
  if self._active and self._active.closingAtTick and tick > self._active.closingAtTick then
    self._active = nil
  end
end

---@return boolean
function FieldMenuHost:isModal()
  return self._active ~= nil and self._active.closingAtTick == nil
end

-- The renderer receives a value snapshot instead of reaching into the host's
-- private live state. The task remains the only owner of menu interaction.
---@return { definition: FieldMenuController.Spec, selectedIndex: integer, layout: table }|nil
function FieldMenuHost:presentation()
  if not self:isModal() then
    return nil
  end
  local active = assert(self._active, "modal menu requires active state")
  return {
    definition = active.definition,
    selectedIndex = active.selectedIndex,
    layout = assert(active.layout, "active menu layout is missing"),
  }
end

---@param events table[]
---@return table[]
function FieldMenuHost:inputEvents(events)
  assert(type(events) == "table", "menu UI events are required")
  local active = self._active
  if active == nil then
    return {}
  end
  local layout = assert(active.layout, "active menu layout is missing")
  local translated = {}
  local selectedIndex = active.selectedIndex
  for _, event in ipairs(events) do
    if event.type == "pointer_move" then
      local itemIndex = itemAt(layout, event.x, event.y)
      translated[#translated + 1] = { type = "pointer_move", itemIndex = itemIndex }
      selectedIndex = itemIndex or selectedIndex
    elseif event.type == "pointer_down" then
      if layout.cancelRect and contains(layout.cancelRect, event.x, event.y) then
        translated[#translated + 1] = { type = "cancel" }
      else
        translated[#translated + 1] = { type = "pointer_down", itemIndex = itemAt(layout, event.x, event.y) }
      end
    elseif event.type == "pointer_up" then
      translated[#translated + 1] = {
        type = "pointer_up",
        itemIndex = itemAt(layout, event.x, event.y),
        dragged = event.dragged == true,
      }
    elseif event.type == "pointer_scroll" then
      local direction = event.dy > 0 and "up" or event.dy < 0 and "down" or nil
      local itemIndex = direction and MenuLayout.adjacentItem(layout, selectedIndex, direction)
      if itemIndex ~= nil then
        translated[#translated + 1] = { type = "focus", itemIndex = itemIndex }
        selectedIndex = itemIndex
      end
    elseif event.type == "navigate" then
      local itemIndex = MenuLayout.adjacentItem(layout, selectedIndex, event.direction)
      if itemIndex ~= nil then
        translated[#translated + 1] = { type = "focus", itemIndex = itemIndex }
        selectedIndex = itemIndex
      end
    else
      translated[#translated + 1] = event
    end
  end
  return translated
end

-- This is semantic presentation state for non-rendering hosts. Closed menus
-- deliberately expose no geometry, so no stale surface state survives.
---@return table
function FieldMenuHost:snapshot()
  if self._active == nil then
    return { modal = false }
  end
  return {
    modal = true,
    itemRects = assert(self._active.layout, "active menu layout is missing").itemRects,
    layout = assert(self._active.layout, "active menu layout is missing"),
  }
end

return FieldMenuHost
