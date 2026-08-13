-- Synthetic tests for the field-actor timeline members. Covers slot selection at
-- a threshold boundary, uneven per-frame durations, palette-slot animation, and
-- the malformed-member rejections. No ROM bytes are involved.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("tests.support.FieldActorFixture")
local FieldActorTimeline = require("romdump.src.digest.FieldActorTimeline")

local T = {}

-- A four-slot loop per direction, four ticks each, like the ordinary-humanoid
-- timeline: sixteen entries covering frames 0..63.
local function uniform()
  local entries, slots = {}, { 0, 8, 9, 10, 11, 12, 13, 14, 15, 1, 2, 3, 4, 5, 6, 7 }
  for i, slot in ipairs(slots) do
    entries[i] = { threshold = (i - 1) * 4, textureSlot = slot }
  end
  return assert(FieldActorTimeline.decode(Fixture.timeline(entries)))
end

local function failsWith(code, bytes)
  local result, err = FieldActorTimeline.decode(bytes, "fixture")
  Assert.isNil(result)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(assert(err).code, code)
end

function T.decodes_count_thresholds_and_slots()
  local timeline = uniform()
  Assert.equal(timeline.count, 16)
  Assert.equal(timeline.entries[0].threshold, 0)
  Assert.equal(timeline.entries[0].textureSlot, 0)
  Assert.equal(timeline.entries[15].threshold, 60)
  Assert.equal(timeline.entries[15].textureSlot, 7)
end

function T.selects_the_last_entry_at_or_below_the_frame()
  local timeline = uniform()
  Assert.equal(FieldActorTimeline.at(timeline, 0), 0)
  Assert.equal(FieldActorTimeline.at(timeline, 3), 0)
  Assert.equal(FieldActorTimeline.at(timeline, 4), 8)
  Assert.equal(FieldActorTimeline.at(timeline, 63), 7)
  -- Beyond the last threshold the final entry holds.
  Assert.equal(FieldActorTimeline.at(timeline, 4096), 7)
end

function T.collapses_a_range_into_displayed_frames()
  local timeline = uniform()
  local frames = FieldActorTimeline.framesForRange(timeline, { startFrame = 0, endFrame = 15 })
  Assert.equal(#frames, 4)
  Assert.deepEqual(frames, {
    { textureSlot = 0, paletteSlot = 0, ticks = 4 },
    { textureSlot = 8, paletteSlot = 0, ticks = 4 },
    { textureSlot = 9, paletteSlot = 0, ticks = 4 },
    { textureSlot = 10, paletteSlot = 0, ticks = 4 },
  })
end

function T.preserves_uneven_frame_durations()
  -- Marill's south-facing loop: 5 ticks, 10 ticks, then 5 back on the first slot.
  local timeline = assert(FieldActorTimeline.decode(Fixture.timeline({
    { threshold = 0, textureSlot = 2 },
    { threshold = 5, textureSlot = 3 },
    { threshold = 15, textureSlot = 2 },
  })))
  local frames = FieldActorTimeline.framesForRange(timeline, { startFrame = 0, endFrame = 19 })
  Assert.deepEqual(frames, {
    { textureSlot = 2, paletteSlot = 0, ticks = 5 },
    { textureSlot = 3, paletteSlot = 0, ticks = 10 },
    { textureSlot = 2, paletteSlot = 0, ticks = 5 },
  })
end

function T.palette_slots_participate_in_frame_identity()
  local timeline = assert(FieldActorTimeline.decode(Fixture.timeline({
    { threshold = 0, textureSlot = 4, paletteSlot = 0 },
    { threshold = 2, textureSlot = 4, paletteSlot = 1 },
  })))
  local _, palette = FieldActorTimeline.at(timeline, 2)
  Assert.equal(palette, 1)
  local frames = FieldActorTimeline.framesForRange(timeline, { startFrame = 0, endFrame = 3 })
  Assert.equal(#frames, 2, "a palette change starts a new displayed frame")
end

function T.rejects_size_mismatch()
  failsWith(
    "FIELD_ACTOR_TIMELINE_SIZE_MISMATCH",
    Fixture.timeline({ { threshold = 0, textureSlot = 0 } }, { trailer = "\0\0" })
  )
  failsWith(
    "FIELD_ACTOR_TIMELINE_SIZE_MISMATCH",
    Fixture.timeline({ { threshold = 0, textureSlot = 0 } }, { declaredCount = 4 })
  )
end

function T.rejects_zero_count_and_truncated_member()
  failsWith("FIELD_ACTOR_TIMELINE_COUNT_INVALID", Fixture.u32(0))
  failsWith("FIELD_ACTOR_TIMELINE_TRUNCATED", "\0\0")
end

function T.rejects_non_monotonic_thresholds()
  failsWith(
    "FIELD_ACTOR_TIMELINE_UNORDERED",
    Fixture.timeline({
      { threshold = 0, textureSlot = 0 },
      { threshold = 8, textureSlot = 1 },
      { threshold = 4, textureSlot = 2 },
    })
  )
end

function T.rejects_a_timeline_that_does_not_start_at_frame_zero()
  failsWith(
    "FIELD_ACTOR_TIMELINE_NO_ORIGIN",
    Fixture.timeline({
      { threshold = 3, textureSlot = 0 },
    })
  )
end

return { tests = T }
