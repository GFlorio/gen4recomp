-- Source-backed movement lifetimes and pose cadences at the HGSS engine's
-- 30 Hz fixed tick. Pure domain module: no love dependency.

local MovementCalibration = {}

-- Ticks per walked tile, keyed by the DSL speed enum.
MovementCalibration.SPEED_TICKS = {
  slower = 32,
  slow = 16,
  normal = 8,
  fast = 4,
  faster = 2,
  slightly_fast = 6,
  slightly_faster = 3,
  fastest = 2,
  -- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
  -- asm/unk_02062108.s commands 88-91 use a four-update run lifetime.
  run = 4,
  hgss_96 = 16,
  hgss_97 = 8,
  hgss_98 = 4,
  hgss_99 = 2,
}

-- Ticks per walk-in-place cycle (on-spot animation step), by speed.
MovementCalibration.WALK_IN_PLACE_TICKS = {
  -- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
  -- asm/unk_02062108.s commands 24-39 use configured countdowns of 32,
  -- 16, 8, and 4, plus one update before completing.
  slower = 33,
  slow = 17,
  normal = 9,
  fast = 5,
  faster = 3,
}

-- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
-- asm/unk_02062108.s: commands 44-47 are slow zero jumps (16 updates),
-- 48-51 are fast zero jumps (8), 52-55 are fast near jumps (8), and
-- 56-59 are fast far jumps (16). Unsupported pairs are not assigned a
-- plausible fallback.
MovementCalibration.JUMP_TICKS = {
  zero = { slow = 16, fast = 8 },
  near = { fast = 8 },
  far = { fast = 16 },
  farther = { fast = 12 },
}

MovementCalibration.FACE_TICKS = 1
MovementCalibration.REVEAL_TRAINER_TICKS = 9
local REVEAL_TRAINER_OFFSETS = {
  0,
  0.25,
  0.5,
  0.6875,
  0.75,
  0.6875,
  0.5625,
  0.375,
  0,
}
-- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
-- asm/overlay_01_022001E4.s, ov01_02200614: the exclamation effect's
-- entrance and completion progression surrounds a 30-update hold.
MovementCalibration.EMOTE_TICKS = 33
-- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
-- asm/unk_02062108.s and asm/unk_data_020FDB44.s: gesture commands
-- 67, 68, 100, 102, 104 map to semantic names warp_out, warp_in,
-- nurse_bow, give, receive; lifetime counts the per-update state machine
-- including whether setup and final steps chain in the same map-object
-- update via sub_02062400's nonzero chaining.
local GESTURE_PROFILE = {
  warp_out = { durationTicks = 20 },
  warp_in = { durationTicks = 20 },
  nurse_bow = { durationTicks = 10 },
  give = { durationTicks = 22 },
  receive = { durationTicks = 22 },
}

-- Vertical arc heights for jump presentation (world units / tiles).
MovementCalibration.JUMP_HEIGHTS = {
  zero = 0.5,
  near = 0.9,
  far = 1.2,
}

local FARTHER_JUMP_OFFSETS = {
  0.375,
  0.5,
  0.625,
  0.75,
  0.75,
  0.75,
  0.6875,
  0.5625,
  0.5,
  0.375,
  0.25,
  0,
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
    slower = { 0, 1 },
    faster = { 4 },
    slightly_faster = { 3, 2, 3 },
    fastest = { 1 },
    hgss_96 = { 1 },
    hgss_97 = { 1 },
    hgss_98 = { 1 },
    hgss_99 = { 1 },
  },
  walk_in_place = {
    slower = { 0, 1 },
    slow = { 0, 1 },
    normal = { 1 },
    fast = { 2 },
    faster = { 4 },
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
  if action.action == "trajectory_segment" then
    return progressTicks
  end
  local actionCadences = POSE_CADENCES[action.action]
  local cadence = actionCadences and actionCadences[action.speed]
  assert(cadence, "unknown pose cadence " .. tostring(action.action) .. " " .. tostring(action.speed))
  return cumulativePoseProgress(cadence, progressTicks)
end

function MovementCalibration.trajectoryProgressAt(progressTicks, durationTicks)
  assert(
    type(progressTicks) == "number" and progressTicks % 1 == 0 and progressTicks >= 0,
    "trajectory progress must be a non-negative integer"
  )
  assert(
    type(durationTicks) == "number" and durationTicks % 1 == 0 and durationTicks > 0,
    "trajectory duration must be a positive integer"
  )
  assert(progressTicks <= durationTicks, "trajectory progress exceeds duration")
  if progressTicks >= durationTicks then
    return 1
  end
  return (progressTicks - 1) / durationTicks
end

function MovementCalibration.trajectoryArcAt(progressTicks, durationTicks)
  assert(
    type(progressTicks) == "number" and progressTicks % 1 == 0 and progressTicks >= 0,
    "trajectory progress must be a non-negative integer"
  )
  assert(
    type(durationTicks) == "number" and durationTicks % 1 == 0 and durationTicks > 0,
    "trajectory duration must be a positive integer"
  )
  assert(progressTicks <= durationTicks, "trajectory progress exceeds duration")
  if progressTicks <= 1 or progressTicks >= durationTicks then
    return 0
  end
  return math.sin(math.rad((progressTicks - 1) * (180 / durationTicks))) * 1.0
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
    local jumpTicks = MovementCalibration.JUMP_TICKS[action.distance]
    return assert(
      jumpTicks and jumpTicks[action.speed],
      "unknown jump distance/speed " .. tostring(action.distance) .. " " .. tostring(action.speed)
    )
  elseif kind == "delay" then
    return action.ticks
  elseif kind == "emote" then
    return MovementCalibration.EMOTE_TICKS
  elseif kind == "gesture" then
    local profile = GESTURE_PROFILE[action.name]
    assert(profile, "unknown gesture " .. tostring(action.name))
    return profile.durationTicks
  elseif kind == "reveal_trainer" then
    return MovementCalibration.REVEAL_TRAINER_TICKS
  elseif kind == "trajectory_segment" then
    assert(
      type(action.ticks) == "number" and action.ticks % 1 == 0 and action.ticks > 0,
      "trajectory ticks must be a positive integer"
    )
    return action.ticks
  end
  error("unknown movement action " .. tostring(kind))
end

function MovementCalibration.jumpOffsetAt(action, progressTicks, durationTicks)
  assert(
    type(progressTicks) == "number" and progressTicks % 1 == 0 and progressTicks >= 0,
    "jump progress must be a non-negative integer"
  )
  assert(
    type(durationTicks) == "number" and durationTicks % 1 == 0 and durationTicks > 0,
    "jump duration must be a positive integer"
  )
  assert(progressTicks <= durationTicks, "jump progress exceeds duration")
  if action.distance == "farther" then
    assert(
      progressTicks >= 1 and progressTicks <= #FARTHER_JUMP_OFFSETS,
      "farther jump progress must be 1.." .. tostring(#FARTHER_JUMP_OFFSETS)
    )
    assert(durationTicks == #FARTHER_JUMP_OFFSETS, "farther jump duration mismatches calibrated ticks")
    return FARTHER_JUMP_OFFSETS[progressTicks]
  end
  local h = MovementCalibration.JUMP_HEIGHTS[action.distance] or 0
  local t = progressTicks / durationTicks
  return 4 * h * t * (1 - t)
end

function MovementCalibration.revealTrainerOffsetAt(progressTicks)
  assert(
    type(progressTicks) == "number" and progressTicks % 1 == 0 and progressTicks >= 1 and progressTicks <= 9,
    "reveal progress must be 1..9"
  )
  return REVEAL_TRAINER_OFFSETS[progressTicks]
end

function MovementCalibration.gesturePresentationAt(name, progressTicks, durationTicks)
  local profile = GESTURE_PROFILE[name]
  assert(profile, "unknown gesture " .. tostring(name))
  assert(
    type(progressTicks) == "number" and progressTicks % 1 == 0 and progressTicks >= 0,
    "gesture progress must be a non-negative integer"
  )
  assert(
    type(durationTicks) == "number" and durationTicks % 1 == 0 and durationTicks > 0,
    "gesture duration must be a positive integer"
  )
  assert(durationTicks == profile.durationTicks, "gesture duration mismatches calibrated ticks for " .. tostring(name))
  assert(progressTicks <= durationTicks, "gesture progress exceeds duration for " .. tostring(name))
  if name == "warp_out" then
    return { pose = nil, poseTick = nil, offsetY = progressTicks }
  elseif name == "warp_in" then
    return { pose = nil, poseTick = nil, offsetY = durationTicks - progressTicks }
  elseif name == "nurse_bow" then
    if progressTicks >= 1 and progressTicks <= 8 then
      return { pose = "nurse_bow", poseTick = progressTicks - 1, offsetY = 0 }
    end
    return { pose = nil, poseTick = nil, offsetY = 0 }
  elseif name == "give" then
    assert(progressTicks >= 1, "gesture give requires progress >= 1")
    return { pose = "give", poseTick = progressTicks - 1, offsetY = 0 }
  elseif name == "receive" then
    assert(progressTicks >= 1, "gesture receive requires progress >= 1")
    return { pose = "receive", poseTick = progressTicks - 1, offsetY = 0 }
  end
  error("unknown gesture " .. tostring(name))
end

function MovementCalibration.gestureFacingAt(name, progressTicks)
  local profile = GESTURE_PROFILE[name]
  assert(profile, "unknown gesture " .. tostring(name))
  assert(
    type(progressTicks) == "number" and progressTicks % 1 == 0 and progressTicks >= 0,
    "gesture progress must be a non-negative integer"
  )
  if name == "nurse_bow" and progressTicks >= 9 then
    return "south"
  end
  return nil
end

function MovementCalibration.gesturePresentationAfterCommit(name, durationTicks)
  local profile = GESTURE_PROFILE[name]
  assert(profile, "unknown gesture " .. tostring(name))
  assert(
    type(durationTicks) == "number" and durationTicks % 1 == 0 and durationTicks > 0,
    "gesture duration must be a positive integer"
  )
  assert(durationTicks == profile.durationTicks, "gesture duration mismatches calibrated ticks for " .. tostring(name))
  if name == "warp_out" then
    return { pose = nil, poseTick = nil, offsetY = 20 }
  elseif name == "warp_in" then
    return { pose = nil, poseTick = nil, offsetY = 0 }
  elseif name == "nurse_bow" then
    return { pose = nil, poseTick = nil, offsetY = 0 }
  elseif name == "give" then
    return MovementCalibration.gesturePresentationAt(name, durationTicks, durationTicks)
  elseif name == "receive" then
    return MovementCalibration.gesturePresentationAt(name, durationTicks, durationTicks)
  end
  error("unknown gesture " .. tostring(name))
end

return MovementCalibration
