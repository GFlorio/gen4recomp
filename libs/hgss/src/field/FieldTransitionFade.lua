-- Owns the fixed-point standard field fade recurrence one source frame at a
-- time. Rendering consumes the exposed coefficient; it does not advance it.

local StandardFade = require("libs.hgss.src.presentation.StandardFade")

---@class FieldTransitionFade
---@field coefficient integer
---@field color integer
---@field direction "in"|"out"
---@field updates integer
---@field completed boolean
local FieldTransitionFade = {}
FieldTransitionFade.__index = FieldTransitionFade

function FieldTransitionFade.new(options)
  local fade = StandardFade.new(options)
  ---@cast fade FieldTransitionFade
  return setmetatable(fade, FieldTransitionFade)
end

function FieldTransitionFade:updateSourceFrame()
  return StandardFade.updateSourceFrame(self)
end

---@return table<string, unknown>
function FieldTransitionFade:status()
  return StandardFade.status(self)
end

return FieldTransitionFade
