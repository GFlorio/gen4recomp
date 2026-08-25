-- FieldScriptScreenFade: the pure semantic controller behind source
-- `FadeScreen`/`WaitFade`. It advances only from an explicit
-- `updateSourceFrame()` call (the 60 Hz presentation clock owns cadence);
-- nothing here reads a renderer or an audio service.
--
-- The module is required per-test (not at file scope) so a missing module
-- fails each contract individually with its own diagnostic instead of
-- discovery losing the whole suite to one load-time require error.

local Assert = require("tests.support.Assert")

local T = {}

local OPENING_OUT = { direction = "out", color = "black", duration = 6, speed = 1 }
local OPENING_IN = { direction = "in", color = "black", duration = 6, speed = 1 }
local ACTIVE_COEFFICIENTS = { 2, 5, 7, 10, 13, 16 }

local function newFade()
  local FieldScriptScreenFade = require("libs.engine.src.FieldScriptScreenFade")
  return FieldScriptScreenFade.new()
end

function T.idle_before_any_fade_reports_done()
  local fade = newFade()
  Assert.isTrue(fade:fadeDone(), "an idle controller has no pending fade to wait on")
  Assert.isFalse(fade:isOpaque(), "an idle controller is not opaque")
end

function T.opening_fade_out_follows_the_standard_six_frame_coefficients()
  local fade = newFade()
  fade:startFade(OPENING_OUT)
  Assert.isFalse(fade:fadeDone(), "a started fade is not immediately done")
  for index, expected in ipairs(ACTIVE_COEFFICIENTS) do
    fade:updateSourceFrame()
    local status = fade:status()
    Assert.equal(status.coefficient, expected, "coefficient after update " .. index)
    Assert.equal(status.direction, "out")
    Assert.equal(status.color, "black")
    Assert.equal(fade:fadeDone(), index == #ACTIVE_COEFFICIENTS, "fade completes only at the final source frame")
  end
  Assert.isTrue(fade:isOpaque(), "a completed fade-out must be fully opaque")
end

function T.opening_fade_in_reverses_to_clear()
  local fade = newFade()
  fade:startFade(OPENING_IN)
  for _, expected in ipairs(ACTIVE_COEFFICIENTS) do
    fade:updateSourceFrame()
    Assert.equal(fade:status().coefficient, 16 - expected)
  end
  Assert.isTrue(fade:fadeDone())
  Assert.isFalse(fade:isOpaque(), "a completed fade-in must be fully clear")
  Assert.equal(fade:status().coefficient, 0)
end

function T.white_color_is_supported()
  local fade = newFade()
  fade:startFade({ direction = "out", color = "white", duration = 6, speed = 1 })
  fade:updateSourceFrame()
  Assert.equal(fade:status().color, "white")
end

function T.unsupported_color_raises_explicit_diagnostics()
  local fade = newFade()
  local ok, err = pcall(function()
    fade:startFade({ direction = "out", color = "green", duration = 6, speed = 1 })
  end)
  Assert.isFalse(ok, "an unrecognized fade color must not be coerced to black")
  Assert.isTrue(tostring(err):find("color", 1, true) ~= nil, "the diagnostic names the unsupported color")
end

function T.unsupported_duration_speed_pair_raises_explicit_diagnostics()
  local fade = newFade()
  local ok = pcall(function()
    fade:startFade({ direction = "out", color = "black", duration = 10, speed = 3 })
  end)
  Assert.isFalse(ok, "an unimplemented duration/speed combination must not silently interpolate")
end

function T.starting_a_second_fade_while_one_is_active_is_a_programming_error()
  local fade = newFade()
  fade:startFade(OPENING_OUT)
  fade:updateSourceFrame()
  local ok = pcall(function()
    fade:startFade(OPENING_IN)
  end)
  Assert.isFalse(ok, "two concurrent script screen fades must never blend")
end

function T.rendering_never_advances_the_controller()
  -- Rendering only reads status(); nothing but updateSourceFrame() may
  -- change the coefficient. This is a contract test, not a real renderer:
  -- calling status() repeatedly must never itself progress the fade.
  local fade = newFade()
  fade:startFade(OPENING_OUT)
  local before = fade:status().coefficient
  fade:status()
  fade:status()
  Assert.equal(fade:status().coefficient, before, "status() must be read-only")
end

return { tests = T }
