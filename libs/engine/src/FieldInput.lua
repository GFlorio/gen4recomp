-- Converts directional and semantic button edges into deterministic fixed-tick
-- snapshots. The most recently pressed held direction wins; each press edge is
-- consumed once so FieldPlayer can buffer it without depending on render
-- cadence. Action and Cancel are semantic buttons: any number of physical
-- bindings collapse into one edge per tick, held state is separate from the
-- edge, and focus loss or a transition commit clears them.
-- Each semantic button tracks the physical sources that hold it down (opaque
-- identities such as "key:enter", "key:space", "gamepad:1:a" supplied by the
-- caller): a button stays down until the last source is released, and a
-- repeat press from an already-held source produces no new edge.

---@class FieldInput
---@field held table<string, boolean>
---@field order table<string, integer>
---@field nextOrder integer
---@field actionSources table<string, boolean>
---@field actionDown boolean
---@field actionPressed boolean
---@field cancelSources table<string, boolean>
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

---@param source string
local function requireSource(source)
  assert(type(source) == "string" and source ~= "", "physical button source identity required")
end

---@return FieldInput
function FieldInput.new()
  return setmetatable({
    held = {},
    order = {},
    nextOrder = 0,
    actionSources = {},
    actionDown = false,
    actionPressed = false,
    cancelSources = {},
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

-- Semantic Action: the first physical source down raises the button and emits
-- one press edge; a further source (or a repeat press of a held source) stays
-- silent until the button rises again -- the edge fires only on the zero-to-one
-- source transition.

---@param source string
function FieldInput:pressAction(source)
  requireSource(source)
  if self.actionSources[source] then
    return
  end
  local wasDown = next(self.actionSources) ~= nil
  self.actionSources[source] = true
  self.actionDown = true
  if not wasDown then
    self.actionPressed = true
  end
end

---@param source string
function FieldInput:releaseAction(source)
  requireSource(source)
  self.actionSources[source] = nil
  if not next(self.actionSources) then
    self.actionDown = false
  end
end

---@param source string
function FieldInput:pressCancel(source)
  requireSource(source)
  if self.cancelSources[source] then
    return
  end
  local wasDown = next(self.cancelSources) ~= nil
  self.cancelSources[source] = true
  self.cancelDown = true
  if not wasDown then
    self.cancelPressed = true
  end
end

---@param source string
function FieldInput:releaseCancel(source)
  requireSource(source)
  self.cancelSources[source] = nil
  if not next(self.cancelSources) then
    self.cancelDown = false
  end
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
-- later tick could act on; held state survives.
function FieldInput:clearEdges()
  self.pressedDirection = nil
  self.actionPressed = nil
  self.cancelPressed = nil
end

-- Focus loss clears held and edge state entirely, including every physical
-- button source so a stray release after refocus cannot mutate a cleared
-- button.
function FieldInput:clearAll()
  self:clearEdges()
  self.held = {}
  self.order = {}
  self.actionSources = {}
  self.actionDown = false
  self.cancelSources = {}
  self.cancelDown = false
end

-- One fixed-tick snapshot: held directions/buttons plus the consumed edges.

---@class FieldInput.Snapshot
---@field heldDirection string?
---@field pressedDirection string?
---@field actionDown boolean
---@field actionPressed boolean?
---@field cancelDown boolean
---@field cancelPressed boolean?

return FieldInput
