-- Headless theme geometry tests: the dialogue box is the canonical HGSS
-- content rect 16,152,216,32 (2/19/27/4 tiles at 8px) inside the centered
-- 4:3 reference canvas at 4:3, 16:9, and ultrawide aspects, with constant
-- reference-space dimensions and two full 16px text lines inside the 32px
-- height. Layout returns reference-canvas geometry plus one origin/scale
-- mapping; screenRect() projects any rect.

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

function T.box_is_the_canonical_hgss_content_rect()
  local box = FieldDialogueTheme.box
  Assert.deepEqual(box, { x = 16, y = 152, width = 216, height = 32 }, "canonical dialogue content rect")
  -- Two 16px text lines fit exactly inside the 32px content height.
  Assert.isTrue(
    FieldDialogueTheme.textInsetY * 2 + FieldDialogueTheme.lineHeight * FieldDialogueTheme.maxLines <= box.height,
    "two 16px lines fit in the content height"
  )
  -- The text area stays inside the box horizontally.
  Assert.isTrue(
    FieldDialogueTheme.textInsetX * 2 + FieldDialogueTheme.textWidth <= box.width,
    "text area inside the box"
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
  Assert.near(box.width, 216 * layout.scale)
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

-- The frame tilemap is the audited DrawFrameAndWindow2 composition
-- (asm/render_window.s sub_0200E6B4 at the pinned decomp commit): the
-- window content box is 27x4 tiles at (2,19), and the frame fills the full
-- 256x192 reference canvas around it -- one tile above and below, two tiles
-- left, three right, all 18 strip tiles placed. Tiles are given in strip
-- order; a span entry repeats the tile across the named axis.
function T.frame_tile_placements_match_the_draw_frame_and_window2_composition()
  local placements = FieldDialogueTheme.frameTilePlacements(FieldDialogueTheme.box)
  Assert.deepEqual(placements, {
    { tile = 0, x = 0, y = 144 },
    { tile = 1, x = 8, y = 144 },
    { tile = 2, x = 16, y = 144, spanX = 27 },
    { tile = 3, x = 232, y = 144 },
    { tile = 4, x = 240, y = 144 },
    { tile = 5, x = 248, y = 144 },
    { tile = 6, x = 0, y = 152, spanY = 4 },
    { tile = 7, x = 8, y = 152, spanY = 4 },
    { tile = 9, x = 232, y = 152, spanY = 4 },
    { tile = 10, x = 240, y = 152, spanY = 4 },
    { tile = 11, x = 248, y = 152, spanY = 4 },
    { tile = 12, x = 0, y = 184 },
    { tile = 13, x = 8, y = 184 },
    { tile = 14, x = 16, y = 184, spanX = 27 },
    { tile = 15, x = 232, y = 184 },
    { tile = 16, x = 240, y = 184 },
    { tile = 17, x = 248, y = 184 },
  }, "frame tiles compose the window around the content box")
  -- The frame never covers the content region (16,152,216,32) and never
  -- escapes the 256x192 reference canvas.
  local box = FieldDialogueTheme.box
  local function overlaps(a, b)
    return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
  end
  for _, p in ipairs(placements) do
    local rect = { x = p.x, y = p.y, width = 8 * (p.spanX or 1), height = 8 * (p.spanY or 1) }
    Assert.isFalse(overlaps(rect, box), "frame tile " .. p.tile .. " must not cover the content rect")
    Assert.isTrue(rect.x >= 0 and rect.x + rect.width <= FieldDialogueTheme.referenceWidth, "tile inside canvas")
    Assert.isTrue(rect.y >= 0 and rect.y + rect.height <= FieldDialogueTheme.referenceHeight, "tile inside canvas")
  end
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

return { tests = T }
