-- AnimationPlayer: format-neutral playback of one clip.
--
-- Frames are fixed-point: frameFx = frame * FRAME_UNIT, and the player
-- advances by deltaFx each updateFixed(). HGSS's field animation manager
-- steps 0x1000 per tick, wraps at either end, and tracks finite completion;
-- this player keeps that behavior for the default delta while permitting
-- arbitrary signed deltas. The frame is always clamped to
-- [0, frameCount * FRAME_UNIT - 1] -- the same window
-- NNSi_G3dAnmCalcNsBca clamps into -- so a decoder fed an out-of-range
-- frame from another source reproduces the SDK's last-key behavior, not a
-- hard error.
--
-- Loop modes:
--   "loop"   wrap at both ends forever
--   "once"   clamp at the end (forward or reverse) and mark completed
--   "repeat" wrap like "loop" while repeatsRemaining > 0, then clamp and mark
--            completed; repeatsRemaining counts completed wraps
--
-- The player knows nothing about clips' source formats: it consumes only the
-- frame count. Pure domain module.

local AnimationClip = require("libs.engine.src.AnimationClip")

local AnimationPlayer = {}
AnimationPlayer.__index = AnimationPlayer

AnimationPlayer.LOOP_MODES = { loop = true, once = true, ["repeat"] = true }
AnimationPlayer.FRAME_UNIT = AnimationClip.FRAME_UNIT

-- Build a player for a clip (or any object with a positive integer
-- frameCount). The returned player is owned by the caller (or an attachment)
-- and is mutable -- two players over one clip never share state.
function AnimationPlayer.new(clip)
  assert(type(clip) == "table" and clip.frameCount ~= nil, "AnimationPlayer.new requires a clip with a frameCount")
  local frameCount = clip.frameCount
  assert(
    type(frameCount) == "number" and frameCount >= 1 and math.floor(frameCount) == frameCount,
    "clip frameCount must be a positive integer"
  )
  return setmetatable({
    frameCount = frameCount,
    frameFx = 0,
    deltaFx = AnimationPlayer.FRAME_UNIT,
    paused = false,
    loopMode = "loop",
    repeatsRemaining = nil,
    completed = false,
  }, AnimationPlayer)
end

-- The inclusive maximum frame value in fixed-point.
function AnimationPlayer:maxFx()
  return self.frameCount * AnimationPlayer.FRAME_UNIT - 1
end

-- Clamp an arbitrary fixed-point frame into the playable window.
function AnimationPlayer:clampFx(frameFx)
  local maxFx = self:maxFx()
  if frameFx < 0 then
    return 0
  end
  if frameFx > maxFx then
    return maxFx
  end
  return frameFx
end

-- (Re)start playback from the current position; if the player already
-- completed, restart from the first frame. Playing is the caller's
-- acknowledgement that a fresh run began.
function AnimationPlayer:play()
  if self.completed then
    self:restart()
  else
    self.paused = false
  end
end

function AnimationPlayer:pause()
  self.paused = true
end

-- Direction is a sign on the delta; the speed is preserved.
function AnimationPlayer:setDirection(direction)
  assert(direction == 1 or direction == -1, "direction must be 1 or -1")
  self.deltaFx = math.abs(self.deltaFx) * direction
end

-- Arbitrary signed fixed-point delta; zero pauses advancement for the
-- duration of the zero delta.
function AnimationPlayer:setDeltaFx(deltaFx)
  assert(type(deltaFx) == "number" and math.floor(deltaFx) == deltaFx, "deltaFx must be an integer")
  self.deltaFx = deltaFx
end

-- Seek to a fixed-point frame (clamped). A seek is an explicit user action:
-- it clears completion so a previously finished clip can be watched again.
function AnimationPlayer:seekFx(frameFx)
  self.frameFx = self:clampFx(frameFx)
  self.completed = false
end

function AnimationPlayer:seekFirst()
  self:seekFx(0)
end

function AnimationPlayer:seekLast()
  self:seekFx(self:maxFx())
end

function AnimationPlayer:restart()
  self.frameFx = 0
  self.completed = false
  self.paused = false
end

-- Advance one fixed step. Wraps or completes per the loop mode; reverse
-- playback wraps/completes at the first frame symmetrically.
function AnimationPlayer:updateFixed()
  if self.paused or self.completed then
    return
  end
  local stepFx = self.frameCount * AnimationPlayer.FRAME_UNIT
  local maxFx = self:maxFx()
  local frameFx = self.frameFx + self.deltaFx

  if frameFx > maxFx then
    if self.loopMode == "once" then
      self.frameFx = maxFx
      self.completed = true
      return
    end
    if self.loopMode == "repeat" and self.repeatsRemaining then
      self.repeatsRemaining = self.repeatsRemaining - 1
      if self.repeatsRemaining <= 0 then
        self.frameFx = maxFx
        self.completed = true
        return
      end
    end
    -- "loop" (and "repeat" with repeats left) wrap past the end; the Lua
    -- modulo yields a frame in [0, stepFx - 1] for any signed overshoot.
    self.frameFx = frameFx % stepFx
    return
  end

  if frameFx < 0 then
    if self.loopMode == "once" then
      self.frameFx = 0
      self.completed = true
      return
    end
    if self.loopMode == "repeat" and self.repeatsRemaining then
      self.repeatsRemaining = self.repeatsRemaining - 1
      if self.repeatsRemaining <= 0 then
        self.frameFx = 0
        self.completed = true
        return
      end
    end
    self.frameFx = frameFx % stepFx
    return
  end

  self.frameFx = frameFx
end

function AnimationPlayer:isComplete()
  return self.completed
end

return AnimationPlayer
