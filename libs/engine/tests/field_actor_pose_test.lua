-- Pose-clock tests: per-frame durations rather than a uniform frame length,
-- looping versus held one-shot poses, direction selection, and the documented
-- idle fallback for a class whose walk clip is absent.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorPose = require("libs.engine.src.FieldActorPose")

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

return T
