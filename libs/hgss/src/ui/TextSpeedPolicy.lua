-- Owns the field text-printer timing policy shared by dialogue and typed
-- signpost text. Delays are the printer's internal blank-update counters.

local TextSpeedPolicy = {}

local POLICIES = {
  slow = { interGlyphDelay = 7, glyphBudget = 1, abAcceleration = true },
  mid = { interGlyphDelay = 3, glyphBudget = 1, abAcceleration = true },
  fast = { interGlyphDelay = 0, glyphBudget = 1, abAcceleration = true },
  fastest = { interGlyphDelay = 0, glyphBudget = 2, abAcceleration = false },
}

---@param textSpeed string
---@return { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean }
function TextSpeedPolicy.forSpeed(textSpeed)
  local policy = POLICIES[textSpeed]
  assert(policy ~= nil, "unknown text speed " .. tostring(textSpeed))
  return {
    interGlyphDelay = policy.interGlyphDelay,
    glyphBudget = policy.glyphBudget,
    abAcceleration = policy.abAcceleration,
  }
end

return TextSpeedPolicy
