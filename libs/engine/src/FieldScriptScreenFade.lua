-- The pure semantic controller behind source `FadeScreen`/`WaitFade`. It
-- advances only from an explicit `updateSourceFrame()` call driven by the
-- 60 Hz presentation clock; nothing here reads a renderer or an audio
-- service, so the same timeline holds headless and in presentation.
-- Pure domain module: no love dependency.

---@class FieldScriptScreenFade
---@field private _active boolean
---@field private _completed boolean
---@field private _direction string|nil
---@field private _color string|nil
---@field private _coefficient integer
---@field private _brightnessFx integer
---@field private _deltaFx integer
---@field private _stepsRemaining integer
---@field private _framesIntoStep integer
---@field private _target integer
---@field private _speed integer
local FieldScriptScreenFade = {}
FieldScriptScreenFade.__index = FieldScriptScreenFade

local function truncTowardZero(value)
  if value >= 0 then
    return math.floor(value)
  end
  return math.ceil(value)
end

---@return FieldScriptScreenFade
function FieldScriptScreenFade.new()
  return setmetatable({
    _active = false,
    _completed = true,
    _direction = nil,
    _color = nil,
    _coefficient = 0,
    _brightnessFx = 0,
    _deltaFx = 0,
    _stepsRemaining = 0,
    _framesIntoStep = 0,
    _target = 0,
    _speed = 1,
  }, FieldScriptScreenFade)
end

-- Begin a screen fade. Starting a second fade while one is still active is a
-- programming/source-sequencing error: two concurrent script screen fades
-- must never blend.
---@param spec { direction: "out"|"in", color: string, duration: integer, speed: integer }
function FieldScriptScreenFade:startFade(spec)
  assert(self:fadeDone(), "a script screen fade is already active")
  assert(
    type(spec.duration) == "number" and spec.duration % 1 == 0 and spec.duration > 0,
    "fade duration must be a positive integer"
  )
  assert(
    type(spec.speed) == "number" and spec.speed % 1 == 0 and spec.speed > 0,
    "fade speed must be a positive integer"
  )
  assert(spec.direction == "out" or spec.direction == "in", "unsupported fade direction " .. tostring(spec.direction))
  assert(spec.color == "black" or spec.color == "white", "unsupported fade color " .. tostring(spec.color))
  local start, target
  if spec.direction == "out" then
    if spec.color == "black" then
      start, target = 0, -16
    else
      start, target = 0, 16
    end
  else
    if spec.color == "black" then
      start, target = -16, 0
    else
      start, target = 16, 0
    end
  end
  self._active = true
  self._completed = false
  self._direction = spec.direction
  self._color = spec.color
  self._brightnessFx = start * 128
  self._deltaFx = truncTowardZero(((target - start) * 128) / spec.duration)
  self._stepsRemaining = spec.duration
  self._framesIntoStep = 0
  self._target = target
  self._speed = spec.speed
  self._coefficient = math.abs(truncTowardZero(self._brightnessFx / 128))
end

-- True while idle: nothing has started, or the started fade fully completed.
-- `WaitFade` normally follows a `FadeScreen`, so the idle state before any
-- fade must not itself block a script.
---@return boolean
function FieldScriptScreenFade:fadeDone()
  if not self._active then
    return true
  end
  return self._completed
end

-- True only once a fade-out has driven the coefficient fully opaque. Idle
-- and a completed fade-in are both not opaque.
---@return boolean
function FieldScriptScreenFade:isOpaque()
  return self._active and self._coefficient == 16
end

-- Advance exactly one source-frame tick. A no-op before any fade started or
-- once it has completed; rendering must never call this.
function FieldScriptScreenFade:updateSourceFrame()
  if not self._active or self._completed then
    return
  end
  self._framesIntoStep = self._framesIntoStep + 1
  if self._framesIntoStep < self._speed then
    return
  end
  self._framesIntoStep = 0
  self._stepsRemaining = self._stepsRemaining - 1
  if self._stepsRemaining > 0 then
    self._brightnessFx = self._brightnessFx + self._deltaFx
    self._coefficient = math.abs(truncTowardZero(self._brightnessFx / 128))
  else
    self._brightnessFx = self._target * 128
    self._coefficient = math.abs(self._target)
    self._completed = true
  end
end

-- Read-only status for the scheduler poll and for presentation/acceptance
-- observation. Never mutates the controller.
---@return table
function FieldScriptScreenFade:status()
  if not self._active then
    return { active = false, direction = nil, color = nil, coefficient = 0, completed = true, overlay = nil }
  end
  local overlay
  if self._coefficient > 0 then
    local channel = self._color == "white" and 1 or 0
    overlay = { r = channel, g = channel, b = channel, a = math.min(1, math.max(0, self._coefficient / 16)) }
  end
  return {
    active = not self._completed,
    direction = self._direction,
    color = self._color,
    coefficient = self._coefficient,
    completed = self._completed,
    overlay = overlay,
  }
end

return FieldScriptScreenFade
