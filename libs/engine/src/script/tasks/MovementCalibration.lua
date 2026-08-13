-- Movement calibration: v1 tick durations per HGSS movement speed
-- profile, at the engine's 30 Hz fixed tick. The pinned decomp does not
-- decompile the movement engine (EventObjectMovementMan lives in an
-- overlay), so these values are documented calibrations; the
-- hgss_96..hgss_99 names preserve distinct source profiles whose final
-- timings may be supplied later. Pure domain module: no love dependency.

local MovementCalibration = {}

-- Ticks per walked tile, keyed by the DSL speed enum.
MovementCalibration.SPEED_TICKS = {
  slower = 24,
  slow = 16,
  normal = 8,
  fast = 4,
  faster = 2,
  slightly_fast = 6,
  slightly_faster = 5,
  fastest = 2,
  run = 2,
  hgss_96 = 16,
  hgss_97 = 8,
  hgss_98 = 4,
  hgss_99 = 2,
}

-- Ticks per walk-in-place cycle (on-spot animation step), by speed.
MovementCalibration.WALK_IN_PLACE_TICKS = {
  slower = 24,
  slow = 16,
  normal = 8,
  fast = 4,
}

-- Ticks per jump, by distance (zero/near/far).
MovementCalibration.JUMP_TICKS = {
  zero = 4,
  near = 6,
  far = 8,
}

MovementCalibration.FACE_TICKS = 1
MovementCalibration.EMOTE_TICKS = 4
MovementCalibration.GESTURE_TICKS = 4

-- Resolve the tick duration of one movement action. The
-- speed/distance enums are schema-constrained, so an unknown value is a
-- programming invariant violation, never a silent default.
---@param action table
---@return integer
function MovementCalibration.actionTicks(action)
  local kind = action.action
  if kind == "face" then
    return MovementCalibration.FACE_TICKS
  elseif kind == "walk" then
    return assert(MovementCalibration.SPEED_TICKS[action.speed], "unknown walk speed " .. tostring(action.speed))
  elseif kind == "walk_in_place" then
    return assert(
      MovementCalibration.WALK_IN_PLACE_TICKS[action.speed],
      "unknown walk_in_place speed " .. tostring(action.speed)
    )
  elseif kind == "jump" then
    return assert(
      MovementCalibration.JUMP_TICKS[action.distance],
      "unknown jump distance " .. tostring(action.distance)
    )
  elseif kind == "delay" then
    return action.ticks
  elseif kind == "emote" then
    return MovementCalibration.EMOTE_TICKS
  elseif kind == "gesture" then
    return MovementCalibration.GESTURE_TICKS
  end
  error("unknown movement action " .. tostring(kind))
end

return MovementCalibration
