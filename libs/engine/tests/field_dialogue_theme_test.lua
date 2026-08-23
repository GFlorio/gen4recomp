local Assert = require("tests.support.Assert")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}

function T.local_window_geometry_is_source_authentic()
  Assert.deepEqual(FieldDialogueTheme.localBox, { x = 16, y = 8, width = 216, height = 32 })
  local layout = FieldDialogueTheme.layout({ x = 0, y = 0, width = 640, height = 480 }, 2)
  Assert.deepEqual(layout.box, FieldDialogueTheme.localBox)
  Assert.deepEqual(layout.text, { x = 26, y = 8, width = 196, height = 32 })
  Assert.deepEqual(layout.cursor, { x = 202, y = 26, width = 10, height = 8 })
  Assert.equal(layout.lineHeight, 16)
end

function T.frame_tiles_remain_inside_the_local_outer_window()
  local placements = FieldDialogueTheme.frameTilePlacements(FieldDialogueTheme.localBox)
  Assert.equal(#placements, 17)
  for _, placement in ipairs(placements) do
    local rect =
      { x = placement.x, y = placement.y, width = 8 * (placement.spanX or 1), height = 8 * (placement.spanY or 1) }
    Assert.isTrue(rect.x >= 0 and rect.y >= 0 and rect.x + rect.width <= 256 and rect.y + rect.height <= 48)
  end
end

function T.font_metrics_keep_glyph_advances_and_controls_widthless()
  local def = FieldUiFixture.cardFontDef()
  local metrics = FieldDialogueTheme.fontMetrics(def)
  Assert.equal(metrics.glyphWidth(1), def.glyphs[1].advance)
  local glyphs = assert(FieldMessageProvider.asciiGlyphTokens("AAAA", def))
  local styled = { { kind = "style", control = 0xFF00, args = { 1 }, raw = { 0xFFFE, 0xFF00, 1, 1 } } }
  for i, token in ipairs(glyphs) do
    styled[i + 1] = token
  end
  Assert.equal(metrics.glyphWidth(0), def.glyphs[0].advance)
  Assert.isTrue(#styled > #glyphs)
end

return { tests = T }
