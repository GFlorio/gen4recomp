-- Converts directional button edges into deterministic fixed-tick snapshots.
-- The most recently pressed held direction wins; each press edge is consumed
-- once so FieldPlayer can buffer it without depending on render cadence.

local FieldInput = {}
FieldInput.__index = FieldInput

local VALID = { north = true, south = true, west = true, east = true }

local function requireDirection(direction)
  assert(VALID[direction], "unknown field direction " .. tostring(direction))
end

function FieldInput.new()
  return setmetatable({ held = {}, order = {}, nextOrder = 0 }, FieldInput)
end

function FieldInput:press(direction)
  requireDirection(direction)
  if self.held[direction] then return end
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

function FieldInput:isHeld(direction)
  requireDirection(direction)
  return self.held[direction] == true
end

function FieldInput:heldDirection()
  local selected, selectedOrder
  for direction, order in pairs(self.order) do
    if not selectedOrder or order > selectedOrder then
      selected, selectedOrder = direction, order
    end
  end
  return selected
end

function FieldInput:snapshot()
  local snapshot = { heldDirection = self:heldDirection() }
  if self.pressedDirection then snapshot.pressedDirection = self.pressedDirection end
  self.pressedDirection = nil
  return snapshot
end

return FieldInput
