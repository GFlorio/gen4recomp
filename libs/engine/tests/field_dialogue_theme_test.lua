-- Headless theme geometry tests: the dialogue
-- box lives inside the centered 4:3 reference canvas at 4:3, 16:9, and
-- ultrawide aspects, with constant reference-space dimensions and two full
-- text lines of extracted font height. Layout returns reference-canvas
-- geometry plus one origin/scale mapping; screenRect() projects any rect.

local Assert = require("tests.support.Assert")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local function frame(width, height)
  return FieldViewport.new(width, height, { mode = "expanded" }).referenceFrame
end

local function screen(layout, rect)
  return FieldDialogueTheme.screenRect(layout, rect)
end

function T.box_is_bottom_anchored_inside_the_reference_canvas()
  local box = FieldDialogueTheme.box
  Assert.equal(box.width, 240)
  Assert.equal(box.height, 56)
  Assert.equal(box.x, 8)
  Assert.equal(box.y + box.height, 192 - 8, "bottom inset is 8 reference pixels")
  -- Two 16px text lines plus symmetric padding fit inside the box height.
  Assert.isTrue(
    FieldDialogueTheme.textInsetY * 2 + FieldDialogueTheme.lineHeight * FieldDialogueTheme.maxLines <= box.height,
    "two lines fit with padding"
  )
end

-- The renderer draws under one translate(origin)+scale transform, so layout
-- geometry must stay in reference-canvas coordinates at every host aspect;
-- screen-mapped output there would be scaled twice and pushed off-screen.
function T.reference_geometry_stays_in_reference_canvas()
  for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1920, 720 } }) do
    local layout = FieldDialogueTheme.layout(frame(size[1], size[2]))
    Assert.isTrue(layout.box.x >= 0 and layout.box.y >= 0, "box in reference space")
    Assert.isTrue(layout.box.x + layout.box.width <= FieldDialogueTheme.referenceWidth + 1e-9)
    Assert.isTrue(layout.box.y + layout.box.height <= FieldDialogueTheme.referenceHeight + 1e-9)
    Assert.isTrue(
      layout.text.y >= layout.box.y and layout.text.y + layout.text.height <= layout.box.y + layout.box.height + 1e-9,
      "text area inside the box"
    )
  end
end

function T.layout_maps_inside_the_reference_frame_at_43()
  local layout = FieldDialogueTheme.layout(frame(960, 720))
  Assert.near(layout.scale, 720 / 192)
  Assert.deepEqual(layout.origin, { x = 0, y = 0 })
  local box = screen(layout, layout.box)
  Assert.near(box.width, 240 * layout.scale)
  Assert.isTrue(box.x >= 0 and box.y >= 0, "box inside frame")
  Assert.isTrue(box.x + box.width <= 960 + 1e-9)
  Assert.isTrue(box.y + box.height <= 720 + 1e-9)
end

function T.layout_maps_inside_the_centered_frame_at_169()
  local reference = frame(1280, 720)
  Assert.near(reference.width, 720 * 4 / 3)
  Assert.near(reference.x, (1280 - reference.width) / 2)
  local layout = FieldDialogueTheme.layout(reference)
  local box = screen(layout, layout.box)
  Assert.isTrue(box.x >= reference.x and box.x + box.width <= reference.x + reference.width + 1e-9)
  Assert.isTrue(box.y >= reference.y and box.y + box.height <= reference.y + reference.height + 1e-9)
end

function T.layout_maps_inside_the_centered_frame_ultrawide()
  local reference = frame(1920, 720)
  local layout = FieldDialogueTheme.layout(reference)
  local box = screen(layout, layout.box)
  Assert.isTrue(
    box.x >= reference.x and box.x + box.width <= reference.x + reference.width + 1e-9,
    "box does not spill into ultrawide gutters"
  )
  Assert.isTrue(box.y >= reference.y and box.y + box.height <= reference.y + reference.height + 1e-9)
end

function T.text_area_fits_two_lines_of_font_height()
  local layout = FieldDialogueTheme.layout(frame(960, 720))
  local box = screen(layout, layout.box)
  local text = screen(layout, layout.text)
  Assert.isTrue(text.y + layout.lineHeight * layout.scale * FieldDialogueTheme.maxLines <= box.y + box.height + 1e-9)
  Assert.near(text.width, FieldDialogueTheme.textWidth * layout.scale)
  -- The cursor sits inside the text area's bottom-right corner.
  local cursor = screen(layout, layout.cursor)
  Assert.isTrue(cursor.x >= text.x and cursor.x + cursor.width <= text.x + text.width + 1e-9)
  Assert.isTrue(cursor.y + cursor.height <= text.y + text.height + 1e-9)
end

function T.font_metrics_resolve_advances_with_fallback()
  local fontDef = {}
  fontDef.glyphs = {
    [1] = { advance = 6 },
    [0] = { advance = 4 },
  }
  local metrics = FieldDialogueTheme.fontMetrics(fontDef)
  Assert.equal(metrics.glyphWidth(1), 6)
  Assert.equal(metrics.glyphWidth(99), 4, "unknown codes use the fallback glyph")
end

return T
