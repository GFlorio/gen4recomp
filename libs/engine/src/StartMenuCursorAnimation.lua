-- Fixed-tick cursor animation for the Start Menu: the generated manifest's
-- cursor frames (their durations) are the cadence authority, and the
-- animation advances exactly once per fixed tick, wrapping after the last
-- frame. Pure state: no LÖVE, no I/O. The Start Menu controller owns an
-- instance and steps it on fixed ticks; the renderer receives only the
-- current frame index in the presentation snapshot, so render refresh rate
-- cannot change the animation speed.

---@class StartMenuCursorAnimation
---@field _frames { duration: integer }[]
---@field _frameIndex integer zero-based index into _frames
---@field _ticksInFrame integer
local StartMenuCursorAnimation = {}
StartMenuCursorAnimation.__index = StartMenuCursorAnimation

-- frames: the generated manifest's startMenu.cursor.frames array (1-based
-- rect+duration entries; only duration is consumed here).

---@param frames { duration: integer }[]
---@return StartMenuCursorAnimation
function StartMenuCursorAnimation.new(frames)
  assert(type(frames) == "table", "cursor animation requires the manifest cursor frames")
  assert(#frames >= 1, "cursor animation requires at least one frame")
  for index, frame in ipairs(frames) do
    assert(
      type(frame) == "table" and type(frame.duration) == "number" and frame.duration % 1 == 0 and frame.duration >= 1,
      "cursor frame " .. index .. " needs a positive integral duration"
    )
  end
  return setmetatable({ _frames = frames, _frameIndex = 0, _ticksInFrame = 0 }, StartMenuCursorAnimation)
end

-- One fixed tick: the current frame holds for its manifest duration, then
-- the animation moves to the next frame and wraps.
function StartMenuCursorAnimation:updateFixed()
  local duration = self._frames[self._frameIndex + 1].duration
  self._ticksInFrame = self._ticksInFrame + 1
  if self._ticksInFrame >= duration then
    self._frameIndex = (self._frameIndex + 1) % #self._frames
    self._ticksInFrame = 0
  end
end

-- The presentation-ready snapshot: the current zero-based frame index the
-- renderer draws.

---@return { frameIndex: integer }
function StartMenuCursorAnimation:status()
  return { frameIndex = self._frameIndex }
end

return StartMenuCursorAnimation
