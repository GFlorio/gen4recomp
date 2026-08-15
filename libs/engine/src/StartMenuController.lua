-- The pure Start Menu controller: the final interactive action display,
-- selection, confirm/cancel, and touch/pointer slot interaction of the HGSS
-- Start Menu, plus the folded-in fixed-tick cursor animation. It consumes
-- the runtime-composed final action list (the intersection of the source
-- policy with the registered destination applications; display-array
-- positions follow StartMenu_BuildActionLists, src/start_menu.c at the
-- pinned decomp commit 008257708), the generated manifest slot surface (the
-- 2x5 slot grid keyed by the source touch-menu ids: slot 1 is the cancel
-- region and touch ids 2..10 are display positions 0..8, StartMenu_
-- HandleTouchInput start_menu.c:613-659), and the generated cursor frames
-- (the manifest is the structural validation boundary, so the controller
-- only reads their durations). An empty action list is first-class: the
-- menu opens with no selection and no cursor, navigation and confirm are
-- safe no-ops, pointer action slots are inert, and the cancel region stays
-- live. The controller is silent -- the branch does not reproduce the
-- source Start Menu effects (SEQ_SE_DP_WIN_OPEN/SELECT and
-- SEQ_SE_GS_GEARCANCEL); it never touches love and never names a ROM
-- sequence or member number. Pointer events carry canonical logical
-- coordinates (0..255 x 0..191); the layout host maps host coordinates
-- before feeding the controller. No application launches happen here: the
-- controller records the takeResult contract ({ kind = "close" } /
-- { kind = "launch", applicationId }) and the application host launches.

---@class StartMenuController
---@field _visibleActions table<integer, StartMenuController.Action> ordered display positions with entries
---@field _orderedPositions integer[] the visible display positions in ascending order
---@field _selectedPosition integer? nil while the menu has no action
---@field _result table?
---@field _closed boolean
---@field _cursorFrames { duration: integer }[] the manifest cursor frame durations
---@field _cursorFrameIndex integer zero-based index into _cursorFrames
---@field _cursorFrameTicks integer
---@field _slots table<integer, FieldDialogueTheme.Rect>
---@field _pointerId string?
---@field _pointerDown { kind: "cancel"|"action"|"none", position: integer? }?
local StartMenuController = {}
StartMenuController.__index = StartMenuController

-- The cancel touch region is the manifest's slot 1 (the source touch menu id
-- 1); display position p occupies slot id p+2 (touch id p+2).
StartMenuController.CANCEL_SLOT_ID = 1

---@param value any
---@param name string
local function assertFiniteNumber(value, name)
  assert(
    type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be finite"
  )
end

---@param value any
---@param name string
local function assertInteger(value, name)
  assertFiniteNumber(value, name)
  assert(value == math.floor(value), name .. " must be an integer")
end

---@param value any
---@param name string
local function assertPoint(value, name)
  assert(type(value) == "number", name .. " must be a number")
  assertFiniteNumber(value, name)
end

-- The manifest slot surface: ids 1..n with canonical rects. Slot 1 is the
-- cancel region; slots 2..n are the action slots (display positions 0..n-2).
---@param value any
---@return table<integer, FieldDialogueTheme.Rect>
local function validateSlots(value)
  assert(type(value) == "table", "the start menu requires the manifest slot surface")
  local count = 0
  for slotId, rect in pairs(value) do
    assertInteger(slotId, "slot id")
    assert(slotId >= 1, "slot ids start at 1")
    assert(type(rect) == "table", "slot " .. slotId .. " needs a rect")
    for _, field in ipairs({ "x", "y", "width", "height" }) do
      assertFiniteNumber(rect[field], "slot " .. slotId .. " " .. field)
      assert(rect[field] >= 0, "slot " .. slotId .. " " .. field .. " must be non-negative")
    end
    count = count + 1
  end
  assert(count == #value and count >= 2, "the manifest slot surface must be a complete 1..n grid of at least 2 slots")
  return value
end

-- The final interactive action list: every entry already passed the
-- capability intersection, so it carries only its identity, its destination,
-- and its canonical display position. An empty list is valid.
---@param value any
---@return table[]
local function validateEntries(value)
  assert(type(value) == "table", "the start menu requires the final action list")
  for index, entry in ipairs(value) do
    assert(type(entry) == "table", "start menu entry " .. index .. " must be a table")
    assert(type(entry.id) == "string" and entry.id ~= "", "start menu entry " .. index .. " needs an id")
    assert(
      type(entry.targetApplication) == "string" and entry.targetApplication ~= "",
      "an interactive start menu entry needs a destination application id"
    )
    assertInteger(entry.displayPosition, "start menu entry " .. index .. " display position")
    assert(entry.displayPosition >= 0, "start menu entry " .. index .. " display position must be non-negative")
  end
  return value
end

-- The manifest cursor frames: the controller reads only the durations (the
-- manifest itself is the structural validation boundary for the frame rects).
---@param value any
---@return { duration: integer }[]
local function validateCursorFrames(value)
  assert(type(value) == "table", "the start menu requires the manifest cursor frames")
  assert(#value >= 1, "the cursor animation requires at least one frame")
  for index, frame in ipairs(value) do
    assert(
      type(frame) == "table" and type(frame.duration) == "number" and frame.duration % 1 == 0 and frame.duration >= 1,
      "cursor frame " .. index .. " needs a positive integral duration"
    )
  end
  return value
end

---@param entries table[]
---@param slotCount integer
---@return table<integer, StartMenuController.Action>, table[]
local function composeDisplay(entries, slotCount)
  -- The source display array: visible entries write their display position
  -- (later writes win -- special 9/10 overwrite positions 7/8). The array
  -- length is the action slot count (slots 2..n), so position p = slot p+2.
  local capacity = slotCount - 1
  local display = {}
  for _, entry in ipairs(entries) do
    local position = entry.displayPosition
    assert(position < capacity, "start menu display capacity exceeded at position " .. tostring(position))
    display[position] = {
      id = entry.id,
      targetApplication = entry.targetApplication,
      position = position,
      slotId = position + StartMenuController.CANCEL_SLOT_ID + 1,
    }
  end
  local ordered = {}
  for position = 0, capacity - 1 do
    if display[position] then
      ordered[#ordered + 1] = display[position]
    end
  end
  return display, ordered
end

---@param ordered integer[]
---@param position integer
---@return integer orderedIndex
local function orderedIndexAt(ordered, position)
  for index, candidate in ipairs(ordered) do
    if candidate == position then
      return index
    end
  end
  error("selection position is not in the visible action list", 2)
end

-- Restores the remembered selection by action id; falls back to the first
-- action, then nil for an empty list.
---@param ordered table[]
---@param rememberedActionId string?
---@return integer? position
local function initialPosition(ordered, rememberedActionId)
  if rememberedActionId ~= nil then
    for _, action in ipairs(ordered) do
      if action.id == rememberedActionId then
        return action.position
      end
    end
  end
  if ordered[1] ~= nil then
    return ordered[1].position
  end
  return nil
end

---@class StartMenuController.Action
---@field id string
---@field targetApplication string
---@field position integer display position (0-based)
---@field slotId integer manifest slot id

-- opts.entries: the runtime-composed final interactive action list (id /
-- targetApplication / displayPosition), possibly empty. opts.slots: the
-- generated manifest startMenu.slots. opts.cursorFrames: the generated
-- manifest startMenu.cursor.frames. opts.rememberedActionId: the selection
-- remembered across a child-application round trip.
---@param opts { entries: table[], slots: table<integer, FieldDialogueTheme.Rect>, cursorFrames: table[], rememberedActionId?: string? }
---@return StartMenuController
function StartMenuController.new(opts)
  assert(type(opts) == "table", "the start menu controller requires options")
  local entries = validateEntries(opts.entries)
  local slots = validateSlots(opts.slots)
  local display, ordered = composeDisplay(entries, #slots)
  local orderedPositions = {}
  for index, action in ipairs(ordered) do
    orderedPositions[index] = action.position
  end
  local self = setmetatable({
    _visibleActions = display,
    _orderedPositions = orderedPositions,
    _selectedPosition = initialPosition(ordered, opts.rememberedActionId),
    _result = nil,
    _closed = false,
    _cursorFrames = validateCursorFrames(opts.cursorFrames),
    _cursorFrameIndex = 0,
    _cursorFrameTicks = 0,
    _slots = slots,
    _pointerId = nil,
    _pointerDown = nil,
  }, StartMenuController)
  return self
end

---@param slot FieldDialogueTheme.Rect
---@param x number
---@param y number
---@return boolean
local function contains(slot, x, y)
  return x >= slot.x and y >= slot.y and x < slot.x + slot.width and y < slot.y + slot.height
end

-- The slot under a canonical logical point, or nil outside the grid.
---@param slots table<integer, FieldDialogueTheme.Rect>
---@param x number
---@param y number
---@return integer? slotId
local function slotAt(slots, x, y)
  for slotId, rect in pairs(slots) do
    if contains(rect, x, y) then
      return slotId
    end
  end
  return nil
end

---@param slotId integer?
---@return integer? position
local function positionOf(slotId)
  if slotId == nil or slotId <= StartMenuController.CANCEL_SLOT_ID then
    return nil
  end
  return slotId - StartMenuController.CANCEL_SLOT_ID - 1
end

-- One fixed tick of the cursor animation while a selection exists: the
-- current manifest frame holds for its duration, then the animation moves to
-- the next frame and wraps. No selection means no cursor is presented, so
-- nothing advances.
function StartMenuController:_advanceCursor()
  if self._selectedPosition == nil then
    return
  end
  local duration = self._cursorFrames[self._cursorFrameIndex + 1].duration
  self._cursorFrameTicks = self._cursorFrameTicks + 1
  if self._cursorFrameTicks >= duration then
    self._cursorFrameIndex = (self._cursorFrameIndex + 1) % #self._cursorFrames
    self._cursorFrameTicks = 0
  end
end

function StartMenuController:_selectPosition(position)
  assert(self._visibleActions[position] ~= nil, "cannot select an empty display position")
  self._selectedPosition = position
end

function StartMenuController:_moveSelection(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  local ordered = self._orderedPositions
  if #ordered == 0 then
    return
  end
  local current = orderedIndexAt(ordered, self._selectedPosition)
  local delta = (direction == "up" or direction == "left") and -1 or 1
  self:_selectPosition(ordered[((current - 1 + delta) % #ordered) + 1])
end

-- Activation of the selected action. The launch result carries the action id
-- so the application host can restore the selection by id when the child
-- application returns.
function StartMenuController:_activate(position)
  local action = self._visibleActions[position]
  if action then
    self._result = {
      kind = "launch",
      applicationId = action.targetApplication,
      actionId = action.id,
    }
    self._closed = true
  end
end

function StartMenuController:_close()
  self._result = { kind = "close" }
  self._closed = true
end

-- One fixed tick: the cursor animation advances exactly once while a
-- selection exists, then the tick's UI events are consumed. The events are
-- the FieldInput uiSnapshot shapes (navigate/confirm/cancel/pointer_down/
-- pointer_move/pointer_up/pointer_scroll) with pointer coordinates in
-- canonical logical space, plus the host-synthesized "menu" event: while the
-- menu is active the menu button has the same close semantics as HGSS X, and
-- the application host translates a fresh menu edge into it.
---@param uiInput table[]
function StartMenuController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the start menu input must be an event list")
  if self._closed then
    return
  end
  self:_advanceCursor()
  local slots = self._slots
  for _, event in ipairs(uiInput) do
    -- A terminal event (close or a successful activate) ends this tick's
    -- processing: later events must not overwrite the recorded result.
    if self._closed then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "start menu events need a type")
    if event.type == "navigate" then
      self:_moveSelection(event.direction)
    elseif event.type == "confirm" then
      if self._selectedPosition ~= nil then
        self:_activate(self._selectedPosition)
      end
    elseif event.type == "cancel" or event.type == "menu" then
      self:_close()
    elseif event.type == "pointer_move" then
      if self._pointerId == nil then
        assertPoint(event.x, "pointer x")
        assertPoint(event.y, "pointer y")
        local position = positionOf(slotAt(slots, event.x, event.y))
        if position ~= nil and self._visibleActions[position] ~= nil then
          self:_selectPosition(position)
        end
      end
    elseif event.type == "pointer_down" then
      if self._pointerId == nil then
        assertPoint(event.x, "pointer x")
        assertPoint(event.y, "pointer y")
        assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
        self._pointerId = event.pointerId
        local slotId = slotAt(slots, event.x, event.y)
        local position = positionOf(slotId)
        if slotId == StartMenuController.CANCEL_SLOT_ID then
          self._pointerDown = { kind = "cancel" }
        elseif position ~= nil and self._visibleActions[position] ~= nil then
          self:_selectPosition(position)
          self._pointerDown = { kind = "action", position = position }
        else
          self._pointerDown = { kind = "none" }
        end
      end
    elseif event.type == "pointer_up" then
      if event.pointerId == self._pointerId then
        assertPoint(event.x, "pointer x")
        assertPoint(event.y, "pointer y")
        local down = assert(self._pointerDown, "pointer up requires a capture")
        self._pointerId = nil
        self._pointerDown = nil
        if event.dragged ~= true then
          local upSlotId = slotAt(slots, event.x, event.y)
          local upPosition = positionOf(upSlotId)
          if down.kind == "cancel" and upSlotId == StartMenuController.CANCEL_SLOT_ID then
            self:_close()
          elseif down.kind == "action" and upPosition ~= nil and upPosition == down.position then
            self:_activate(upPosition)
          end
        end
      end
    elseif event.type == "pointer_scroll" then
      -- The canonical surface has no scrollable region; scroll changes nothing.
    else
      error("unknown start menu event type " .. tostring(event.type), 2)
    end
  end
end

-- The presentation snapshot: cursor slot/frame for the renderer plus the
-- ordered visible actions. An open menu with no actions presents the cancel
-- region and no cursor. Fresh tables per call; the caller may not mutate
-- controller state through them.
---@return StartMenuController.Status
function StartMenuController:status()
  if self._closed then
    return { open = false }
  end
  local actions = {}
  for position = 0, #self._slots - 2 do
    local action = self._visibleActions[position]
    if action then
      actions[#actions + 1] = {
        id = action.id,
        targetApplication = action.targetApplication,
        position = action.position,
        slotId = action.slotId,
      }
    end
  end
  return {
    open = true,
    actions = actions,
    cancelSlotId = StartMenuController.CANCEL_SLOT_ID,
    cursorSlotId = self._selectedPosition and self._selectedPosition + StartMenuController.CANCEL_SLOT_ID + 1 or nil,
    cursorFrameIndex = self._selectedPosition and self._cursorFrameIndex or nil,
  }
end

-- The result contract: nil until a terminal event, then exactly one
-- { kind = "close" } or { kind = "launch", applicationId }.
---@return { kind: "close"|"launch", applicationId?: string }?
function StartMenuController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

-- Idempotent release of the logical lifetime: the host disposes the active
-- controller on success, cancellation, failure, reset, or runtime disposal.
-- A pending result is discarded (a launch never happens after disposal).
function StartMenuController:dispose()
  self._result = nil
  self._closed = true
end

-- The placement-change contract: a press held across a layout change must
-- not activate a different post-layout slot, so the application host cancels
-- an active pointer capture when the menu placement changes.
function StartMenuController:cancelPointerCapture()
  self._pointerId = nil
  self._pointerDown = nil
end

---@class StartMenuController.Status
---@field open boolean
---@field actions StartMenuController.Action[]
---@field cancelSlotId integer?
---@field cursorSlotId integer?
---@field cursorFrameIndex integer?

return StartMenuController
