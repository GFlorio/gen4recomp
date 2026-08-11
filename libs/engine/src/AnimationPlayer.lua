-- AnimationPlayer: the field-prop checked-advance state machine -- forward
-- only, one completion notion. Frames are fixed-point (frameFx = frame *
-- FRAME_UNIT) and the player advances by one FRAME_UNIT per updateFixed().
-- HGSS's field animation manager steps 0x1000 per tick and reports done
-- through the checked advance: Field3dModelAnimation_FrameAdvanceAndCheck
-- clamps the positive terminal at numFrame << 12 and sets done there
-- (pokeheartgold overlay_01_021FB878.s), so a "once" clip finishes exactly
-- when frameFx reaches frameCount * FRAME_UNIT. The frame is always clamped
-- to [0, frameCount * FRAME_UNIT] -- the checked advance stores numFrame <<
-- 12 as a valid frame -- and a decoder fed an out-of-range frame from another
-- source reproduces the SDK's last-key behavior through its own clamp.
--
-- Loop modes:
--   "loop"   wrap forward at frameCount * FRAME_UNIT forever
--   "once"   land on frameCount * FRAME_UNIT and mark completed
--
-- Terminal-state policy lives here: one completion notion (isComplete), the
-- checked advance's done flag. There is no direction: playback always runs
-- forward from frame 0. The player knows nothing about clips' source formats:
-- it consumes only the frame count. Pure domain module.

local AnimationClip = require("libs.engine.src.AnimationClip")

local AnimationPlayer = {}
AnimationPlayer.__index = AnimationPlayer

AnimationPlayer.LOOP_MODES = { loop = true, once = true }
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
    completed = false,
  }, AnimationPlayer)
end

-- The maximum frame value in fixed-point: the checked-advance terminal
-- numFrame << 12 (a valid frame, not one unit short of it).
function AnimationPlayer:maxFx()
  return self.frameCount * AnimationPlayer.FRAME_UNIT
end

-- Clamp an arbitrary fixed-point frame into the playable window
-- [0, frameCount * FRAME_UNIT].
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

-- Seek to a fixed-point frame (clamped into the checked-advance window). A
-- seek is an explicit user action: it clears completion so a previously
-- finished clip can be watched again.
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

-- Advance one fixed step forward. A once-clip that reaches or passes the
-- checked-advance terminal lands exactly on it and is marked completed; a
-- loop wraps at the terminal.
function AnimationPlayer:updateFixed()
  if self.paused or self.completed then
    return
  end
  local stepFx = self.frameCount * AnimationPlayer.FRAME_UNIT
  local frameFx = self.frameFx + self.deltaFx

  if frameFx >= stepFx then
    if self.loopMode == "once" then
      self.frameFx = stepFx
      self.completed = true
      return
    end
    -- "loop" wraps past the end; the Lua modulo yields a frame in
    -- [0, stepFx - 1] for any forward overshoot.
    self.frameFx = frameFx % stepFx
    return
  end

  self.frameFx = frameFx
end

function AnimationPlayer:isComplete()
  return self.completed
end

return AnimationPlayer
