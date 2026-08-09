-- Converts directional and semantic button edges into deterministic fixed-tick
-- snapshots. The most recently pressed held direction wins; each press edge is
-- consumed once so FieldPlayer can buffer it without depending on render
-- cadence. Action and Cancel are semantic buttons (spec section 11.1): any
-- number of physical bindings collapse into one edge per tick, held state is
-- separate from the edge, and focus loss or a transition commit clears them.

---@class FieldInput
---@field held table<string, boolean>
---@field order table<string, integer>
---@field nextOrder integer
---@field actionDown boolean
---@field actionPressed boolean
---@field cancelDown boolean
---@field cancelPressed boolean
---@field pressedDirection string?
local FieldInput = {}
FieldInput.__index = FieldInput

local VALID = { north = true, south = true, west = true, east = true }

---@param direction string
local function requireDirection(direction)
  assert(VALID[direction], "unknown field direction " .. tostring(direction))
end

---@return FieldInput
function FieldInput.new()
  return setmetatable({
    held = {},
    order = {},
    nextOrder = 0,
    actionDown = false,
    actionPressed = false,
    cancelDown = false,
    cancelPressed = false,
  }, FieldInput)
end

---@param direction string
function FieldInput:press(direction)
  requireDirection(direction)
  if self.held[direction] then
    return
  end
  self.nextOrder = self.nextOrder + 1
  self.held[direction] = true
  self.order[direction] = self.nextOrder
  self.pressedDirection = direction
end

function FieldInput:release(direction)
  requireDirection(direction)
  self.held[direction] = nil
  self.order[direction] = nil
end

---@param direction string
---@return boolean
function FieldInput:isHeld(direction)
  requireDirection(direction)
  return self.held[direction] == true
end

---@return string?
function FieldInput:heldDirection()
  local selected, selectedOrder
  for direction, order in pairs(self.order) do
    if not selectedOrder or order > selectedOrder then
      selected, selectedOrder = direction, order
    end
  end
  return selected
end

function FieldInput:pressAction()
  self.actionDown = true
  self.actionPressed = true
end

function FieldInput:releaseAction()
  self.actionDown = false
end

function FieldInput:pressCancel()
  self.cancelDown = true
  self.cancelPressed = true
end

function FieldInput:releaseCancel()
  self.cancelDown = false
end

-- Snapshot consumes every edge exactly once per fixed tick; held state is
-- carried through so modal consumers can distinguish "held" from "pressed".

---@return FieldInput.Snapshot
function FieldInput:snapshot()
  local snapshot = {
    heldDirection = self:heldDirection(),
    actionDown = self.actionDown,
    cancelDown = self.cancelDown,
  }
  if self.pressedDirection then
    snapshot.pressedDirection = self.pressedDirection
  end
  if self.actionPressed then
    snapshot.actionPressed = true
  end
  if self.cancelPressed then
    snapshot.cancelPressed = true
  end
  self.pressedDirection = nil
  self.actionPressed = nil
  self.cancelPressed = nil
  return snapshot
end

-- Transition commits and dialogue closes must not leave a stale edge that a
-- later tick could act on; held state survives (spec section 11.2).
function FieldInput:clearEdges()
  self.pressedDirection = nil
  self.actionPressed = nil
  self.cancelPressed = nil
end

-- Focus loss clears held and edge state entirely (spec section 11.2).
function FieldInput:clearAll()
  self:clearEdges()
  self.held = {}
  self.order = {}
  self.actionDown = false
  self.cancelDown = false
end

-- One fixed-tick snapshot: held directions/buttons plus the consumed edges
-- (spec section 11.1-11.2).

---@class FieldInput.Snapshot
---@field heldDirection string?
---@field pressedDirection string?
---@field actionDown boolean
---@field actionPressed boolean?
---@field cancelDown boolean
---@field cancelPressed boolean?

return FieldInput
