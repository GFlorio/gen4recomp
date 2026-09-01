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

-- Vertical arc heights for jump presentation (world units / tiles).
MovementCalibration.JUMP_HEIGHTS = {
  zero = 0.5,
  near = 0.9,
  far = 1.2,
}

-- Periodic pose progress deltas, keyed by semantic action and speed.
local POSE_CADENCES = {
  walk = {
    -- Source-backed walk cadences.
    slow = { 0, 1 },
    normal = { 1 },
    fast = { 2 },
    slightly_fast = { 1, 1, 2, 1, 1, 2 },
    run = { 2 },
    -- Explicitly preserve the existing local/unverified walk profiles.
    slower = { 1 },
    faster = { 1 },
    slightly_faster = { 1 },
    fastest = { 1 },
    hgss_96 = { 1 },
    hgss_97 = { 1 },
    hgss_98 = { 1 },
    hgss_99 = { 1 },
  },
  walk_in_place = {
    -- Preserve the existing walk-in-place cadence profiles.
    slower = { 0, 1 },
    slow = { 0, 1 },
    normal = { 1 },
    fast = { 2 },
  },
  jump = {
    -- Preserve the existing jump cadence profiles.
    slow = { 0, 1 },
    fast = { 1 },
    -- Explicitly preserve the other current jump speed profiles.
    slower = { 1 },
    normal = { 1 },
    faster = { 1 },
    slightly_fast = { 1 },
    slightly_faster = { 1 },
    fastest = { 1 },
    run = { 1 },
    hgss_96 = { 1 },
    hgss_97 = { 1 },
    hgss_98 = { 1 },
    hgss_99 = { 1 },
  },
}

-- Compute cumulative pose progress from complete cadence periods and a prefix.
---@param cadence integer[]
---@param progressTicks integer
---@return integer
local function cumulativePoseProgress(cadence, progressTicks)
  local periodProgress = 0
  for _, poseDelta in ipairs(cadence) do
    periodProgress = periodProgress + poseDelta
  end

  local completePeriods = math.floor(progressTicks / #cadence)
  local remainingTicks = progressTicks % #cadence
  local progress = completePeriods * periodProgress
  for tick = 1, remainingTicks do
    progress = progress + cadence[tick]
  end
  return progress
end

-- Convert fixed action progress to cumulative integer pose phase.
---@param action { action: string, speed: string? }
---@param progressTicks integer
---@return integer
function MovementCalibration.poseProgressTicks(action, progressTicks)
  assert(
    type(progressTicks) == "number" and progressTicks >= 0 and progressTicks % 1 == 0,
    "pose progress must be a non-negative integer"
  )
  local actionCadences = POSE_CADENCES[action.action]
  local cadence = actionCadences and actionCadences[action.speed]
  assert(cadence, "unknown pose cadence " .. tostring(action.action) .. " " .. tostring(action.speed))
  return cumulativePoseProgress(cadence, progressTicks)
end

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
