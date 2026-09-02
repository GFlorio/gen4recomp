-- Pose-clock tests: per-frame durations rather than a uniform frame length,
-- looping versus held one-shot poses, direction selection, and the documented
-- idle fallback for a class whose walk clip is absent.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
end

-- Frame 7 for 2 ticks, then frame 9 for 3 ticks: an uneven loop, as the static
-- Marill's south range is in the ROM.
local function unevenPose(loop)
  return {
    frames = { { frameIndex = 7, ticks = 2 }, { frameIndex = 9, ticks = 3 } },
    loop = loop,
    durationTicks = 5,
  }
end

function T.walks_uneven_frame_durations()
  local pose = unevenPose(true)
  local seen = {}
  for tick = 0, 4 do
    seen[#seen + 1] = FieldActorPose.frameIndexAt(pose, tick)
  end
  Assert.deepEqual(seen, { 7, 7, 9, 9, 9 })
end

function T.a_looping_pose_wraps_on_its_total_duration()
  local pose = unevenPose(true)
  Assert.equal(FieldActorPose.frameIndexAt(pose, 5), 7)
  Assert.equal(FieldActorPose.frameIndexAt(pose, 12), 9)
end

function T.a_one_shot_pose_holds_its_last_frame()
  local pose = unevenPose(false)
  Assert.equal(FieldActorPose.frameIndexAt(pose, 4), 9)
  Assert.equal(FieldActorPose.frameIndexAt(pose, 400), 9)
end

function T.selects_the_facing_pose_set()
  local visual = FieldActorFixture.visual(29)
  Assert.equal(FieldActorPose.frameIndex(visual, "north", "idle", 0), 1)
  Assert.equal(
    FieldActorPose.frameIndex(visual, "east", "idle", 0),
    4,
    "each direction holds the first frame of its own range"
  )
  Assert.equal(FieldActorPose.frameIndex(visual, "west", "walk", 2), 5)
end

function T.a_missing_walk_clip_falls_back_to_idle_and_reports_it()
  local visual = FieldActorFixture.visual(29, { omitWalk = true })
  local frameIndex, fellBack = FieldActorPose.frameIndex(visual, "south", "walk", 3)
  Assert.equal(frameIndex, 2)
  Assert.isTrue(fellBack, "the caller must be able to warn once about the substitution")
end

function T.rejects_an_unsupported_facing()
  local visual = FieldActorFixture.visual(29)
  throwsCode("ACTOR_FACING_INVALID", function()
    FieldActorPose.select(visual, "northeast", "idle")
  end)
end

function T.rejects_a_visual_without_the_requested_direction()
  local visual = FieldActorFixture.visual(29)
  visual.directions.north = nil
  throwsCode("ACTOR_POSE_DIRECTION_MISSING", function()
    FieldActorPose.select(visual, "north", "idle")
  end)
end

function T.sample_distinguishes_reused_frame_identity()
  local pose = {
    frames = {
      { frameIndex = 1, ticks = 2, displayOffsetY = 0 },
      { frameIndex = 1, ticks = 2, displayOffsetY = -2 / 16 },
    },
    loop = true,
    durationTicks = 4,
  }
  local first = FieldActorPose.sampleAt(pose, 0)
  local second = FieldActorPose.sampleAt(pose, 2)
  Assert.equal(first.frameIndex, 1)
  Assert.equal(second.frameIndex, 1)
  Assert.equal(first.displayOffsetY, 0)
  Assert.equal(second.displayOffsetY, -2 / 16)
  Assert.equal(FieldActorPose.frameIndexAt(pose, 0), 1)
  Assert.equal(FieldActorPose.frameIndexAt(pose, 2), 1)
  Assert.equal(FieldActorPose.sampleAt(pose, 1).displayOffsetY, 0)
  Assert.equal(FieldActorPose.sampleAt(pose, 3).displayOffsetY, -2 / 16)
end

function T.gesture_frame_index_selects_one_shot_clip_and_clamps()
  local visual = FieldActorFixture.visual(29)
  visual.gestures = {
    give = {
      pose = {
        frames = { { frameIndex = 5, ticks = 2 }, { frameIndex = 6, ticks = 3 } },
        loop = false,
        durationTicks = 5,
      },
      displayOffset = { x = 0, y = 0, z = 1 / 32 },
    },
  }
  Assert.equal(FieldActorPose.gestureFrameIndex(visual, "give", 0), 5)
  Assert.equal(FieldActorPose.gestureFrameIndex(visual, "give", 2), 6)
  Assert.equal(FieldActorPose.gestureFrameIndex(visual, "give", 100), 6, "one-shot clamps at last frame")
end

function T.missing_gesture_clip_raises_structured_error_without_fallback()
  local visual = FieldActorFixture.visual(29)
  visual.gestures = {}
  throwsCode("ACTOR_POSE_MISSING", function()
    FieldActorPose.gestureFrameIndex(visual, "give", 0)
  end)
  local err = Assert.throws(function()
    FieldActorPose.gestureFrameIndex(visual, "nurse_bow", 0)
  end)
  Assert.isTrue(Errors.is(err), "structured error")
  Assert.equal(err.code, "ACTOR_POSE_MISSING")
end

return { tests = T }
