-- Owns the fixed-point standard fade recurrence one source frame at a time.
-- The six-source-frame HGSS cadence (0 -> 2 -> 5 -> 7 -> 10 -> 13 -> 16,
-- normalized by 16) is shared by field transitions and the new-game
-- presentation handoff. Rendering consumes the exposed coefficient; it does
-- not advance it.

---@class StandardFade
---@field coefficient integer
---@field color integer
---@field direction "in"|"out"
---@field updates integer
---@field completed boolean
local StandardFade = {}
StandardFade.__index = StandardFade

local ACTIVE_COEFFICIENTS = { 2, 5, 7, 10, 13, 16 }

function StandardFade.new(options)
  options = options or {}
  local color = options.color or 0
  assert(color == 0 or color == 0x7FFF, "standard fade color must be black or white")
  local direction = options.direction or "out"
  assert(direction == "out" or direction == "in", "standard fade direction required")
  return setmetatable({
    coefficient = direction == "out" and 0 or 16,
    color = color,
    direction = direction,
    updates = 0,
    completed = false,
  }, StandardFade)
end

function StandardFade:updateSourceFrame()
  if self.completed then
    return self.coefficient
  end
  self.updates = self.updates + 1
  local active = ACTIVE_COEFFICIENTS[self.updates]
  assert(active, "standard fade update exceeded duration")
  self.coefficient = self.direction == "out" and active or 16 - active
  self.completed = self.updates == #ACTIVE_COEFFICIENTS
  return self.coefficient
end

---@return table<string, unknown>
function StandardFade:status()
  return {
    coefficient = self.coefficient,
    color = self.color,
    direction = self.direction,
    completed = self.completed,
  }
end

return StandardFade
