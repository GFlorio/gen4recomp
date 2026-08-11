-- AnimationPlayer: the field-prop checked-advance state machine -- forward
-- only, one completion notion. Frames are fixed-point (frameFx = frame *
-- FRAME_UNIT) and advance by one FRAME_UNIT per updateFixed. HGSS's field
-- animation manager steps 0x1000 per tick and reports done through the
-- checked advance (Field3dModelAnimation_FrameAdvanceAndCheck clamps the
-- positive terminal at numFrame << 12 and sets done there; pokeheartgold
-- overlay_01_021FB878.s), so a "once" clip finishes exactly when frameFx
-- reaches frameCount * FRAME_UNIT -- the single completion notion. Reverse
-- playback (setDirection) and the atTerminal/completed split are cut:
-- playback always runs forward from 0, and one finish notion remains.
-- Seeking stays: seekFx/seekFirst/seekLast clamp into the checked-advance
-- window. Pure domain module.

local Assert = require("tests.support.Assert")
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")

local T = {}

local function clip(frameCount)
  return { frameCount = frameCount }
end

local function new(frameCount)
  return AnimationPlayer.new(clip(frameCount))
end

function T.default_state()
  local p = new(8)
  Assert.equal(p.frameFx, 0)
  Assert.equal(p.deltaFx, 0x1000)
  Assert.isFalse(p.paused)
  Assert.equal(p.loopMode, "loop")
  Assert.isFalse(p.completed)
  Assert.isFalse(p:isComplete())
end

function T.advances_one_frame_per_tick()
  local p = new(8)
  p:updateFixed()
  Assert.equal(p.frameFx, 0x1000)
  for _ = 1, 5 do
    p:updateFixed()
  end
  Assert.equal(p.frameFx, 6 * 0x1000)
end

function T.loop_wraps_forward_at_the_terminal()
  local p = new(3)
  for _ = 1, 3 do
    p:updateFixed()
  end
  Assert.equal(p.frameFx, 0, "frame 3 wraps to frame 0")
  Assert.isFalse(p:isComplete())
  p:updateFixed()
  Assert.equal(p.frameFx, 0x1000)
end

-- The single completion notion: a once-clip finishes exactly when frameFx
-- reaches numFrame * FRAME_UNIT -- the positive terminal the checked advance
-- clamps to (numFrame << 12) and reports done at. Not one tick earlier (the
-- old atTerminal last-key-frame notion) and not clamped one unit short (the
-- old completed clamp).
function T.once_completes_exactly_at_numFrame_times_frame_unit()
  local p = new(8)
  p.loopMode = "once"
  for _ = 1, 7 do
    p:updateFixed()
  end
  Assert.equal(p.frameFx, 7 * 0x1000)
  Assert.isFalse(p:isComplete(), "the checked advance is not done before the terminal")
  p:updateFixed()
  Assert.equal(p.frameFx, 8 * 0x1000, "the once clip lands exactly on numFrame * FRAME_UNIT")
  Assert.isTrue(p:isComplete())
  p:updateFixed()
  Assert.equal(p.frameFx, 8 * 0x1000, "completed players stay at the terminal")
  Assert.isTrue(p:isComplete(), "completed players do not advance")
end

function T.the_direction_api_is_cut()
  local p = new(8)
  Assert.isNil(p.setDirection, "setDirection has no caller and must not exist")
  Assert.equal(p.deltaFx, 0x1000, "the step is always forward")
end

function T.the_terminal_split_is_cut()
  local p = new(8)
  Assert.isNil(p.atTerminal, "one completion notion replaces the atTerminal/completed split")
end

function T.pause_and_play()
  local p = new(8)
  p:pause()
  Assert.isTrue(p.paused)
  p:updateFixed()
  Assert.equal(p.frameFx, 0, "paused players do not advance")
  p:play()
  Assert.isFalse(p.paused)
  p:updateFixed()
  Assert.equal(p.frameFx, 0x1000)
end

function T.seek_clamps_into_the_checked_advance_window()
  local p = new(8)
  p.loopMode = "once"
  for _ = 1, 10 do
    p:updateFixed()
  end
  Assert.isTrue(p:isComplete())
  p:seekFx(3 * 0x1000)
  Assert.equal(p.frameFx, 3 * 0x1000)
  Assert.isFalse(p:isComplete(), "a seek clears completion")
  p:seekFx(-4096)
  Assert.equal(p.frameFx, 0)
  p:seekFx(1e9)
  Assert.equal(p.frameFx, 8 * 0x1000, "seeks clamp to the checked-advance terminal")
end

function T.seek_first_and_last()
  local p = new(8)
  p:seekLast()
  Assert.equal(p.frameFx, 8 * 0x1000, "the last frame is numFrame * FRAME_UNIT")
  p:seekFirst()
  Assert.equal(p.frameFx, 0)
end

function T.restart_resets_state()
  local p = new(8)
  p.loopMode = "once"
  for _ = 1, 10 do
    p:updateFixed()
  end
  Assert.isTrue(p:isComplete())
  p:pause()
  p:restart()
  Assert.equal(p.frameFx, 0)
  Assert.isFalse(p.paused)
  Assert.isFalse(p:isComplete())
end

function T.play_after_completion_restarts_forward()
  local p = new(3)
  p.loopMode = "once"
  for _ = 1, 3 do
    p:updateFixed()
  end
  p:play()
  Assert.equal(p.frameFx, 0)
  p:updateFixed()
  Assert.equal(p.frameFx, 0x1000)
end

function T.players_are_independent()
  local a, b = new(8), new(8)
  a.loopMode = "once"
  for _ = 1, 10 do
    a:updateFixed()
    b:updateFixed()
  end
  Assert.isTrue(a:isComplete())
  Assert.isFalse(b:isComplete())
  Assert.equal(a.frameFx, 8 * 0x1000, "the once clip holds at the terminal")
end

return T
