-- Selects which compiled atlas frame a field actor displays, from its facing,
-- its pose name, and the fixed simulation tick.
--
-- The original timeline advances an actor's animation clock one frame per field
-- update while it walks and never advances it while it stands, so a pose is a
-- list of (frame, ticks) pairs walked by a tick counter rather than a uniform
-- frame length. Frame indices are 1-based into the visual's `frames` list, which
-- is also the atlas strip order. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

local FieldActorPose = {}

local FACINGS = { north = true, south = true, west = true, east = true }

-- Walk the pose's per-frame durations. A looping pose wraps on its total
-- duration; a one-shot pose holds its last frame.
function FieldActorPose.frameIndexAt(pose, tick)
  assert(type(pose) == "table" and #pose.frames > 0, "a pose needs at least one frame")
  assert(
    type(tick) == "number" and tick >= 0 and tick == math.floor(tick),
    "a pose clock is a non-negative integer tick"
  )
  local total = pose.durationTicks
  local position = pose.loop and (tick % total) or math.min(tick, total - 1)
  for _, frame in ipairs(pose.frames) do
    if position < frame.ticks then
      return frame.frameIndex
    end
    position = position - frame.ticks
  end
  return pose.frames[#pose.frames].frameIndex
end

-- Resolve the pose set for a facing. `poseName` is "idle" or "walk"; an actor
-- class whose compiled definition lacks the requested clip falls back to its
-- verified idle pose and reports that it did, so the caller can warn once.
function FieldActorPose.select(visualDef, facing, poseName)
  assert(
    type(visualDef) == "table" and type(visualDef.directions) == "table",
    "pose selection needs a compiled actor visual"
  )
  if not FACINGS[facing] then
    Errors.raise(
      FieldErrors.ACTOR_FACING_INVALID,
      "unsupported actor facing " .. tostring(facing),
      { spriteId = visualDef.spriteId, facing = facing }
    )
  end
  local set = visualDef.directions[facing]
  if not set then
    Errors.raise(
      FieldErrors.ACTOR_POSE_DIRECTION_MISSING,
      "sprite " .. tostring(visualDef.spriteId) .. " has no " .. facing .. " pose set",
      { spriteId = visualDef.spriteId, facing = facing }
    )
  end
  local pose = set[poseName]
  if pose then
    return pose, false
  end
  if not set.idle then
    Errors.raise(
      FieldErrors.ACTOR_POSE_MISSING,
      "sprite " .. tostring(visualDef.spriteId) .. " has no " .. tostring(poseName) .. " or idle pose facing " .. facing,
      { spriteId = visualDef.spriteId, facing = facing, pose = poseName }
    )
  end
  return set.idle, true
end

-- The frame a facing/pose/tick triple displays, plus whether idle was
-- substituted for a missing clip.
function FieldActorPose.frameIndex(visualDef, facing, poseName, tick)
  local pose, fellBack = FieldActorPose.select(visualDef, facing, poseName)
  return FieldActorPose.frameIndexAt(pose, tick), fellBack
end

return FieldActorPose
