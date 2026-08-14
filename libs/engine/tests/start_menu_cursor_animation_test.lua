-- Fixed-tick cursor animation for the Start Menu surface: the generated
-- manifest's cursor frames (rects plus durations) are the cadence authority.
-- The animation advances once per fixed tick and exposes the current frame
-- index; render refresh rate cannot change the speed. No LÖVE, no I/O — the
-- controller owns the instance and the renderer consumes only the frame
-- index from its snapshot.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StartMenuCursorAnimation = require("libs.engine.src.StartMenuCursorAnimation")

local T = {}

-- A fresh animation sits on frame 0, so the first frame is visible from the
-- first open tick.
function T.fresh_state_starts_on_frame_zero()
  local anim = StartMenuCursorAnimation.new(FieldUiFixture.START_MENU_CURSOR_FRAMES)
  Assert.equal(anim:status().frameIndex, 0)
end

-- The manifest durations own the cadence: with the fixture's 22/11 split the
-- first frame holds for 22 updates, the second for 11, then the cycle wraps.
function T.fixed_ticks_advance_frames_by_the_manifest_durations()
  local anim = StartMenuCursorAnimation.new(FieldUiFixture.START_MENU_CURSOR_FRAMES)
  for _ = 1, 21 do
    anim:updateFixed()
    Assert.equal(anim:status().frameIndex, 0, "frame 0 holds until the 22nd update")
  end
  anim:updateFixed()
  Assert.equal(anim:status().frameIndex, 1, "the 22nd update switches to frame 1")
  for _ = 1, 10 do
    anim:updateFixed()
    Assert.equal(anim:status().frameIndex, 1, "frame 1 holds for its 11 updates")
  end
  anim:updateFixed()
  Assert.equal(anim:status().frameIndex, 0, "the cycle wraps to frame 0")
end

-- A different injected duration changes the cadence: the pure state never
-- chooses or guesses a speed.
function T.injected_durations_change_the_cadence()
  local anim = StartMenuCursorAnimation.new({ { duration = 3 }, { duration = 5 } })
  for _ = 1, 2 do
    anim:updateFixed()
    Assert.equal(anim:status().frameIndex, 0)
  end
  anim:updateFixed()
  Assert.equal(anim:status().frameIndex, 1, "the 3rd update switches to frame 1")
  for _ = 1, 4 do
    anim:updateFixed()
    Assert.equal(anim:status().frameIndex, 1)
  end
  anim:updateFixed()
  Assert.equal(anim:status().frameIndex, 0)
end

-- A single-frame animation never leaves frame 0: the cursor art that does
-- not animate still ticks without changing identity.
function T.single_frame_animation_stays_on_frame_zero()
  local anim = StartMenuCursorAnimation.new({ { duration = 7 } })
  for _ = 1, 20 do
    anim:updateFixed()
  end
  Assert.equal(anim:status().frameIndex, 0)
end

-- The manifest contract is a non-empty frame array of positive integral
-- durations; anything else is a programming fault.
function T.rejects_malformed_frame_sets()
  local invalid = {
    nil,
    {},
    { { duration = 0 } },
    { { duration = 1.5 } },
    { { duration = "22" } },
    { {} },
  }
  for _, frames in ipairs(invalid) do
    local bad = frames ---@type any
    Assert.throws(function()
      StartMenuCursorAnimation.new(bad)
    end, "malformed cursor frames must be rejected")
  end
end

return { tests = T }
