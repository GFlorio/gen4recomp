-- The pure semantic controller behind source `FadeScreen`/`WaitFade`. It
-- advances only from an explicit `updateSourceFrame()` call driven by the
-- 60 Hz presentation clock; nothing here reads a renderer or an audio
-- service, so the same timeline holds headless and in presentation.
--
-- The opening source parameter pair (duration=6, speed=1) reuses
-- FieldTransitionFade's exact six-frame coefficient recurrence rather than a
-- second literal coefficient table. Only that pinned pair and the black/white
-- source colors are implemented; any other combination is explicit
-- unsupported behavior instead of an invented interpolation. Pure domain
-- module: no love dependency.

local FieldTransitionFade = require("libs.engine.src.FieldTransitionFade")

local COLOR_CODES = { black = 0, white = 0x7FFF }

---@class FieldScriptScreenFade
---@field private _fade FieldTransitionFade|nil
---@field private _color string|nil
local FieldScriptScreenFade = {}
FieldScriptScreenFade.__index = FieldScriptScreenFade

---@return FieldScriptScreenFade
function FieldScriptScreenFade.new()
  return setmetatable({ _fade = nil, _color = nil }, FieldScriptScreenFade)
end

-- Begin a screen fade. Starting a second fade while one is still active is a
-- programming/source-sequencing error: two concurrent script screen fades
-- must never blend.
---@param spec { direction: "out"|"in", color: string, duration: integer, speed: integer }
function FieldScriptScreenFade:startFade(spec)
  assert(self:fadeDone(), "a script screen fade is already active")
  assert(
    spec.duration == 6 and spec.speed == 1,
    "unsupported script screen fade duration/speed " .. tostring(spec.duration) .. "/" .. tostring(spec.speed)
  )
  local colorCode = COLOR_CODES[spec.color]
  assert(colorCode ~= nil, "unsupported script screen fade color " .. tostring(spec.color))
  self._fade = FieldTransitionFade.new({ direction = spec.direction, color = colorCode })
  self._color = spec.color
end

-- True while idle: nothing has started, or the started fade fully completed.
-- `WaitFade` normally follows a `FadeScreen`, so the idle state before any
-- fade must not itself block a script.
---@return boolean
function FieldScriptScreenFade:fadeDone()
  return self._fade == nil or self._fade.completed
end

-- True only once a fade-out has driven the coefficient fully opaque. Idle
-- and a completed fade-in are both not opaque.
---@return boolean
function FieldScriptScreenFade:isOpaque()
  return self._fade ~= nil and self._fade.coefficient == 16
end

-- Advance exactly one source-frame tick. A no-op before any fade started or
-- once it has completed; rendering must never call this.
function FieldScriptScreenFade:updateSourceFrame()
  if self._fade == nil or self._fade.completed then
    return
  end
  self._fade:update60()
end

-- Read-only status for the scheduler poll and for presentation/acceptance
-- observation. Never mutates the controller.
---@return table
function FieldScriptScreenFade:status()
  if self._fade == nil then
    return { active = false, direction = nil, color = nil, coefficient = 0, completed = true, overlay = nil }
  end
  local status = self._fade:status()
  local overlay
  if status.coefficient > 0 then
    local channel = status.color == 0x7FFF and 1 or 0
    overlay = { r = channel, g = channel, b = channel, a = math.min(1, math.max(0, status.coefficient / 16)) }
  end
  return {
    active = not status.completed,
    direction = status.direction,
    color = self._color,
    coefficient = status.coefficient,
    completed = status.completed,
    overlay = overlay,
  }
end

return FieldScriptScreenFade
