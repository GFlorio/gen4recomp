-- AnimationPlayer: fixed-point playback semantics. Frames advance by one
-- FRAME_UNIT per updateFixed (direction flips the sign), wrap at both ends,
-- and track finite completion per loop mode ("loop" or "once"). The
-- terminal state (atTerminal) is the HGSS checked-advance condition shared
-- with the controllers.

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

function T.loop_wraps_forward_at_end()
  local p = new(3)
  for _ = 1, 3 do
    p:updateFixed()
  end
  Assert.equal(p.frameFx, 0, "frame 3 wraps to frame 0")
  Assert.isFalse(p:isComplete())
  p:updateFixed()
  Assert.equal(p.frameFx, 0x1000)
end

function T.loop_wraps_reverse_at_start()
  local p = new(3)
  p:setDirection(-1)
  p:updateFixed()
  Assert.equal(p.frameFx, 2 * 0x1000, "frame 0 reverse wraps to the last frame")
  p:updateFixed()
  Assert.equal(p.frameFx, 1 * 0x1000)
end

function T.once_completes_at_end()
  local p = new(3)
  p.loopMode = "once"
  for _ = 1, 3 do
    p:updateFixed()
  end
  Assert.equal(p.frameFx, p:maxFx(), "clamps at the inclusive last frame")
  Assert.isTrue(p:isComplete())
  p:updateFixed()
  Assert.equal(p.frameFx, p:maxFx(), "completed players do not advance")
end

function T.once_completes_reverse_at_start()
  local p = new(3)
  p.loopMode = "once"
  p:setDirection(-1)
  p:updateFixed()
  Assert.equal(p.frameFx, 0)
  Assert.isTrue(p:isComplete())
end

-- The HGSS checked-advance condition: reaching the direction's terminal
-- frame is the finish condition even before the clamp that marks `completed`
-- fires (a delta that lands exactly on the last key frame).
function T.at_terminal_reports_the_checked_advance_state()
  local p = new(8)
  p.loopMode = "once"
  Assert.isFalse(p:atTerminal(), "frame 0 forward is not terminal")
  for _ = 1, 7 do
    p:updateFixed()
  end
  Assert.equal(p.frameFx, 7 * 0x1000)
  Assert.isTrue(p:atTerminal(), "the last key frame is terminal")
  Assert.isFalse(p:isComplete(), "completion is marked only by the clamp")
  p:updateFixed() -- the clamp fires at the window top
  Assert.isTrue(p:isComplete())

  local q = new(8)
  q:setDirection(-1)
  for _ = 1, 7 do
    q:updateFixed()
  end
  Assert.equal(q.frameFx, 1 * 0x1000)
  Assert.isFalse(q:atTerminal())
  q:updateFixed() -- wraps to the window start
  Assert.equal(q.frameFx, 0)
  Assert.isTrue(q:atTerminal(), "reverse playback is terminal at the window start")
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

function T.set_direction_flips_the_one_frame_step()
  local p = new(8)
  p:setDirection(-1)
  Assert.equal(p.deltaFx, -0x1000)
  p:setDirection(1)
  Assert.equal(p.deltaFx, 0x1000)
end

function T.reverse_restart_completes_at_the_window_start()
  -- A reverse "once" restart always begins at frame 0 -- already the
  -- reverse terminal frame -- so the next update completes in place.
  local p = new(8)
  p.loopMode = "once"
  p:setDirection(-1)
  p:restart()
  Assert.equal(p.frameFx, 0)
  p:updateFixed()
  Assert.equal(p.frameFx, 0)
  Assert.isTrue(p:isComplete())
end

function T.seek_clamps_and_clears_completion()
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
  Assert.equal(p.frameFx, 8 * 0x1000 - 1, "seeks clamp to the inclusive max")
end

function T.seek_first_and_last()
  local p = new(8)
  p:seekLast()
  Assert.equal(p.frameFx, 8 * 0x1000 - 1)
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

function T.play_after_completion_restarts()
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
  b:setDirection(-1)
  for _ = 1, 10 do
    a:updateFixed()
    b:updateFixed()
  end
  Assert.isTrue(a:isComplete())
  Assert.isFalse(b:isComplete())
end

return T
