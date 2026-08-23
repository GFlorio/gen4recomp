-- Converts source FX32 movement deltas into the field world's tile units.
-- HGSS FX32 uses twelve fractional bits; this is the sole conversion owner.

local FieldTransitionMotion = {}

function FieldTransitionMotion.fx32ToWorldUnits(value)
  assert(type(value) == "number" and value == math.floor(value), "FX32 delta must be an integer")
  return value / 4096
end

return FieldTransitionMotion
