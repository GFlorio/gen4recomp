-- FieldViewport adaptive Hor+ and strict 4:3 rectangle policy.

local Assert = require("tests.support.Assert")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}
local function approx(a, b)
  return math.abs(a - b) < 1e-9
end

function T.expanded_uses_full_wide_drawable_and_centered_reference_frame()
  local viewport = FieldViewport.new(1920, 1080, { mode = "expanded" })
  Assert.deepEqual(viewport.worldViewport, { x = 0, y = 0, width = 1920, height = 1080 })
  Assert.isTrue(approx(viewport.referenceFrame.width, 1440))
  Assert.isTrue(approx(viewport.referenceFrame.x, 240))
  Assert.isTrue(approx(viewport:worldAspect(), 16 / 9))
end

function T.strict_centers_a_four_by_three_world_viewport()
  local viewport = FieldViewport.new(1920, 1080, { mode = "strict" })
  Assert.deepEqual(viewport.worldViewport, { x = 240, y = 0, width = 1440, height = 1080 })
  Assert.deepEqual(viewport.referenceFrame, viewport.worldViewport)
  Assert.isTrue(approx(viewport:worldAspect(), 4 / 3))
end

function T.expanded_and_strict_are_identical_at_four_by_three()
  local expanded = FieldViewport.new(1024, 768, { mode = "expanded" })
  local strict = FieldViewport.new(1024, 768, { mode = "strict" })
  Assert.deepEqual(expanded.worldViewport, strict.worldViewport)
  Assert.deepEqual(expanded.referenceFrame, strict.referenceFrame)
end

function T.narrow_expanded_falls_back_to_strict_fit()
  local viewport = FieldViewport.new(900, 900, { mode = "expanded" })
  Assert.deepEqual(viewport.worldViewport, { x = 0, y = 112.5, width = 900, height = 675 })
  Assert.deepEqual(viewport.referenceFrame, viewport.worldViewport)
end

function T.resize_recomputes_rectangles_without_replacing_the_object()
  local viewport = FieldViewport.new(800, 600, { mode = "expanded" })
  for _ = 1, 10 do
    viewport:resize(960, 720)
    viewport:resize(2560, 720)
  end
  viewport:resize(1600, 900)
  Assert.deepEqual(viewport.worldViewport, { x = 0, y = 0, width = 1600, height = 900 })
  Assert.equal(viewport.referenceFrame.x, 200)
end

function T.invalid_dimensions_and_modes_are_rejected()
  Assert.throws(function()
    FieldViewport.new(0, 100)
  end)
  Assert.throws(function()
    FieldViewport.new(100, 100, { mode = "crop" })
  end)
end

-- The one field-pixel scale calculation shared by the renderer (edge radius)
-- and the field-attached UI: one canonical 256x192 field pixel occupies
-- (referenceFrame.height / 192) host pixels at zoom 1, scaled linearly by the
-- effective camera zoom. The result is the exact non-rounded product -- the
-- renderer rounds only when it needs an integer edge-neighbor distance.
local function logicalScaleCases()
  return {
    { width = 1280, height = 720, zoom = 0.5, expected = (720 / 192) * 0.5 },
    { width = 1280, height = 720, zoom = 1.0, expected = (720 / 192) * 1.0 },
    { width = 1280, height = 720, zoom = 1.5, expected = (720 / 192) * 1.5 },
    { width = 1920, height = 1080, zoom = 0.5, expected = (1080 / 192) * 0.5 },
    { width = 1920, height = 1080, zoom = 1.0, expected = (1080 / 192) * 1.0 },
    { width = 1920, height = 1080, zoom = 1.5, expected = (1080 / 192) * 1.5 },
  }
end

function T.logical_pixel_scale_matches_the_formula_in_expanded_mode()
  for _, case in ipairs(logicalScaleCases()) do
    local viewport = FieldViewport.new(case.width, case.height, { mode = "expanded" })
    Assert.equal(viewport.referenceFrame.height, case.height, "expanded reference frame keeps the host height")
    local scale = viewport:logicalPixelScale(case.zoom)
    Assert.near(
      scale,
      case.expected,
      1e-9,
      ("%dx%d zoom %.1f: (referenceFrame.height / 192) * zoom"):format(case.width, case.height, case.zoom)
    )
    Assert.isTrue(scale > 0 and scale == math.floor(scale) + (scale - math.floor(scale)), "non-rounded positive")
    Assert.isTrue(scale ~= math.floor(scale), "the scale is never rounded by FieldViewport")
  end
end

function T.logical_pixel_scale_matches_the_formula_in_strict_fit_mode()
  -- A 4:3 host makes the strict viewport identical to the expanded one; a
  -- 1:1 host (900x900) falls back to a strict fit whose reference frame is
  -- the fitted 4:3 rectangle -- the scale must follow that fitted height, not
  -- the raw host height.
  local cases = {
    { width = 1024, height = 768, zoom = 1.0, expected = (768 / 192) * 1.0 },
    { width = 900, height = 900, zoom = 0.5, expected = (675 / 192) * 0.5 },
    { width = 900, height = 900, zoom = 1.5, expected = (675 / 192) * 1.5 },
  }
  for _, case in ipairs(cases) do
    local viewport = FieldViewport.new(case.width, case.height, { mode = "strict" })
    Assert.near(
      viewport:logicalPixelScale(case.zoom),
      case.expected,
      1e-9,
      "strict/fitted reference frame height drives the scale"
    )
  end
end

function T.logical_pixel_scale_rejects_non_positive_and_non_finite_zoom()
  local viewport = FieldViewport.new(1280, 720)
  for _, zoom in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0 }) do
    Assert.throws(function()
      viewport:logicalPixelScale(zoom)
    end, "effective zoom must be finite and > 0, got " .. tostring(zoom))
  end
end

return { tests = T }
