-- AnimationPlayer: fixed-point playback semantics. Frames advance by
-- FRAME_UNIT per updateFixed, wrap at both ends, support arbitrary signed
-- deltas, and track finite completion per loop mode.

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
  Assert.isNil(p.repeatsRemaining)
  Assert.isFalse(p.completed)
  Assert.isFalse(p:isComplete())
end

function T.advances_one_frame_per_tick()
  local p = new(8)
  p:updateFixed()
  Assert.equal(p.frameFx, 0x1000)
  for _ = 1, 5 do p:updateFixed() end
  Assert.equal(p.frameFx, 6 * 0x1000)
end

function T.loop_wraps_forward_at_end()
  local p = new(3)
  for _ = 1, 3 do p:updateFixed() end
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
  for _ = 1, 3 do p:updateFixed() end
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

function T.finite_repeat_counts_wraps()
  local p = new(3)
  p.loopMode = "repeat"
  p.repeatsRemaining = 2
  p:updateFixed() -- frame 1
  p:updateFixed() -- frame 2
  p:updateFixed() -- wrap, repeatsRemaining 1
  Assert.equal(p.frameFx, 0)
  Assert.isFalse(p:isComplete())
  p:updateFixed() -- frame 1
  p:updateFixed() -- frame 2
  p:updateFixed() -- wrap, repeatsRemaining 0 -> completed
  Assert.equal(p.frameFx, p:maxFx(), "finishes clamped at the end")
  Assert.isTrue(p:isComplete())
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

function T.set_direction_preserves_speed()
  local p = new(8)
  p:setDeltaFx(0x3000)
  p:setDirection(-1)
  Assert.equal(p.deltaFx, -0x3000)
  p:setDirection(1)
  Assert.equal(p.deltaFx, 0x3000)
end

function T.arbitrary_delta_wraps()
  local p = new(8)
  p:setDeltaFx(0x3000) -- three frames per tick
  for _ = 1, 3 do p:updateFixed() end
  Assert.equal(p.frameFx, 1 * 0x1000, "9 frames mod 8 wraps to frame 1")
  p:setDeltaFx(-0x2000)
  p:updateFixed()
  Assert.equal(p.frameFx, 7 * 0x1000, "negative delta wraps backward")
end

function T.seek_clamps_and_clears_completion()
  local p = new(8)
  p.loopMode = "once"
  for _ = 1, 10 do p:updateFixed() end
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
  for _ = 1, 10 do p:updateFixed() end
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
  for _ = 1, 3 do p:updateFixed() end
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
