-- Field-attached dialogue/signpost layout scaling with effective field zoom.
-- The canonical 256x192 surface is scaled by the field logical pixel scale and
-- bottom-centered inside the viewport reference frame.

local Assert = require("tests.support.Assert")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local function referenceFrame(width, height, x, y)
  x = x or 0
  y = y or 0
  -- 4:3 convenient frame: 512x384 (2x) or 768x576 etc.
  return { x = x, y = y, width = width, height = height }
end

function T.canonical_surface_fills_reference_frame_at_unit_zoom()
  local ref = referenceFrame(512, 384, 0, 0)
  local fieldScale = ref.height / 192 -- 2
  local layout = FieldDialogueTheme.layout(ref, fieldScale)
  Assert.near(layout.scale, 2, 1e-9)
  Assert.deepEqual(layout.origin, { x = 0, y = 0 })
  Assert.equal(layout.box.x, 16)
  Assert.equal(layout.box.y, 152)
  Assert.equal(layout.box.width, 216)
  Assert.equal(layout.box.height, 32)
  Assert.equal(layout.text.x, 26)
  Assert.equal(layout.text.y, 152)
  -- scaled canvas fills ref
  Assert.near(layout.origin.x + 256 * layout.scale, ref.x + ref.width, 1e-9)
  Assert.near(layout.origin.y + 192 * layout.scale, ref.y + ref.height, 1e-9)
end

function T.layout_shrinks_but_keeps_bottom_and_center_when_zoomed_out()
  local ref = referenceFrame(512, 384, 0, 0)
  local fieldScale = (ref.height / 192) * 0.5 -- 1
  local layout = FieldDialogueTheme.layout(ref, fieldScale)
  Assert.near(layout.scale, 1, 1e-9)
  -- bottom anchored
  Assert.near(layout.origin.y + 192 * layout.scale, ref.y + ref.height, 1e-9)
  -- horizontal center preserved
  Assert.near(layout.origin.x + 128 * layout.scale, ref.x + ref.width / 2, 1e-9)
  Assert.near(layout.origin.x, 128, 1e-9)
  Assert.near(layout.origin.y, 192, 1e-9)
  -- bottom-center invariants algebraically
  Assert.near(layout.origin.y, ref.y + ref.height - 192 * layout.scale, 1e-9)
  Assert.near(layout.origin.x, ref.x + (ref.width - 256 * layout.scale) / 2, 1e-9)
end

function T.layout_grows_from_bottom_center_when_zoomed_in()
  local ref = referenceFrame(512, 384, 0, 0)
  local fieldScale = (ref.height / 192) * 1.5 -- 3
  local layout = FieldDialogueTheme.layout(ref, fieldScale)
  Assert.near(layout.scale, 3, 1e-9)
  Assert.near(layout.origin.y + 192 * layout.scale, ref.y + ref.height, 1e-9)
  Assert.near(layout.origin.x + 128 * layout.scale, ref.x + ref.width / 2, 1e-9)
  -- top moves up (negative origin when physical larger than ref)
  Assert.isTrue(layout.origin.y < 0, "top moves above reference origin when zoomed in")
  Assert.near(layout.origin.x, -128, 1e-9)
  Assert.near(layout.origin.y, -192, 1e-9)
end

function T.layout_preserves_invariants_with_nonzero_reference_origin()
  local ref = referenceFrame(512, 384, 40, 20)
  for _, zoom in ipairs({ 0.5, 1, 1.5 }) do
    local fieldScale = (ref.height / 192) * zoom
    local layout = FieldDialogueTheme.layout(ref, fieldScale)
    Assert.near(layout.scale, fieldScale, 1e-9)
    Assert.near(layout.origin.y + 192 * layout.scale, ref.y + ref.height, 1e-9, "bottom anchored at zoom " .. zoom)
    Assert.near(layout.origin.x + 128 * layout.scale, ref.x + ref.width / 2, 1e-9, "center at zoom " .. zoom)
    -- logical box stays in reference canvas coordinates
    Assert.isTrue(layout.box.x >= 0 and layout.box.y >= 0)
    Assert.isTrue(layout.box.x + layout.box.width <= 256 + 1e-9)
  end
end

function T.layout_scale_matches_viewport_logical_pixel_scale()
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  local ref = viewport.referenceFrame
  for _, zoom in ipairs({ 0.5, 1, 1.5 }) do
    local fieldScale = viewport:logicalPixelScale(zoom)
    local layout = FieldDialogueTheme.layout(ref, fieldScale)
    Assert.near(layout.scale, fieldScale, 1e-9)
    Assert.near(layout.origin.y + 192 * layout.scale, ref.y + ref.height, 1e-9)
  end
end

return { tests = T }
