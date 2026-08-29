-- Elapsed gameplay-time accumulator. It is inactive until playable field
-- entry, includes modal application time while active, and saturates at the
-- retail display limit without depending on civil time.

---@class PlayTime
---@field _seconds number
---@field _active boolean
local PlayTime = {}
PlayTime.__index = PlayTime

PlayTime.MAX_SECONDS = 3599999

local function isFiniteNonnegative(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value >= 0
end

---@param seconds number?
---@return PlayTime
function PlayTime.new(seconds)
  seconds = seconds or 0
  assert(isFiniteNonnegative(seconds), "PlayTime seconds must be finite and nonnegative")
  assert(seconds <= PlayTime.MAX_SECONDS, "PlayTime seconds exceed the supported cap")
  return setmetatable({ _seconds = seconds, _active = false }, PlayTime)
end

---@return nil
function PlayTime:start()
  self._active = true
end

---@return nil
function PlayTime:stop()
  self._active = false
end

---@param elapsedSeconds number
---@param _ table?
---@return nil
function PlayTime:advance(elapsedSeconds, _)
  assert(isFiniteNonnegative(elapsedSeconds), "PlayTime advance must be finite and nonnegative")
  if self._active then
    self._seconds = math.min(PlayTime.MAX_SECONDS, self._seconds + elapsedSeconds)
  end
end

---@return integer
function PlayTime:seconds()
  return math.floor(self._seconds)
end

---@return boolean
function PlayTime:isActive()
  return self._active
end

return PlayTime
