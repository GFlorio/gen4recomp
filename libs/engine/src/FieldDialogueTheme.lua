-- The single theme record for field dialogue presentation: the 256 x 192
-- reference canvas (matching the DS top-screen aspect),
-- the canonical HGSS message-box content rect, text metrics, colors, cursor
-- blink, and the reference-to-screen mapping into FieldViewport.referenceFrame.
-- The content rect is 16,152,216,32: DIALOG_BOX_X=2, DIALOG_BOX_Y=19,
-- DIALOG_BOX_W=27, DIALOG_BOX_H=4 tiles at 8px/tile (src/dialog_box.c,
-- pret/pokeheartgold commit 008257708bd41df5b8c9037e019088ba24df0a87).
-- All geometry is pure so the box layout is testable headlessly at every
-- host aspect; the LÖVE renderer draws exactly what this module computes.

local FieldMessageText = require("libs.assets.src.FieldMessageText")

---@class FieldDialogueTheme
---@field schema string
---@field referenceWidth integer
---@field referenceHeight integer
---@field box FieldDialogueTheme.Rect
---@field textInsetX integer
---@field textInsetY integer
---@field lineHeight integer
---@field maxLines integer
---@field textWidth integer
---@field textHeight integer
---@field cursor { width: integer, height: integer, offsetX: integer, offsetY: integer, blinkTicks: integer }
---@field colors { fill: number[], border: number[], cursor: number[], marker: number[] }
---@field slice { size: integer, corner: integer }
---@field layout fun(referenceFrame: FieldDialogueTheme.Rect): FieldDialogueTheme.Layout
---@field screenRect fun(layout: FieldDialogueTheme.Layout, rect: FieldDialogueTheme.Rect): FieldDialogueTheme.Rect
---@field fontMetrics fun(fontDef: FieldFontDef): FieldDialogueTheme.Metrics
---@field measureText fun(fontDef: FieldFontDef): fun(text: string): number
local FieldDialogueTheme = {}

FieldDialogueTheme.schema = "g4-field-dialogue-theme-v1"

-- Reference canvas: the DS top screen is 256 x 192.
FieldDialogueTheme.referenceWidth = 256
FieldDialogueTheme.referenceHeight = 192

-- Canonical HGSS message-box content rect: 2 tiles in, 19 tiles down,
-- 27 tiles wide, 4 tiles tall on the 32x24-tile field screen.
FieldDialogueTheme.box = {
  x = 16,
  y = 152,
  width = 216,
  height = 32,
}

-- Text area inside the box: two 16px lines fill the 32px content height
-- (HGSS prints from the window origin); a small horizontal inset keeps the
-- text clear of the window border.
FieldDialogueTheme.textInsetX = 10
FieldDialogueTheme.textInsetY = 0
FieldDialogueTheme.lineHeight = 16
FieldDialogueTheme.maxLines = 2
FieldDialogueTheme.textWidth = 216 - 2 * 10
FieldDialogueTheme.textHeight = 32

-- Cursor: a down-pointing triangle at the text area's bottom-right, blinking
-- on a fixed tick period.
FieldDialogueTheme.cursor = {
  width = 10,
  height = 8,
  offsetX = 6,
  offsetY = 6,
  blinkTicks = 30,
}

-- Colors (project-owned window; the extracted glyph atlas bakes
-- its own ink/shadow/background colors, so text is drawn unmodified).
FieldDialogueTheme.colors = {
  fill = { 0.93, 0.93, 0.97, 0.96 },
  border = { 0.16, 0.20, 0.42, 1 },
  cursor = { 0.10, 0.12, 0.30, 1 },
  marker = { 0.55, 0.25, 0.10, 1 },
}

-- Nine-slice: a 6x6 source image with 2px corners and edges, so
-- the center stretches without seams under nearest filtering.
FieldDialogueTheme.slice = { size = 6, corner = 2 }

-- Reference-to-screen mapping for one viewport. The reference canvas scales
-- uniformly into the centered 4:3 referenceFrame, so wide hosts keep the box
-- inside the canonical frame. All geometry is returned in
-- reference-canvas coordinates; the renderer applies origin + scale once, and
-- screenRect() maps any returned rect to screen pixels. Never return
-- screen-mapped rects here: draw() applies the transform, and double mapping
-- pushes the box off-screen.

---@param referenceFrame FieldDialogueTheme.Rect
---@return FieldDialogueTheme.Layout
function FieldDialogueTheme.layout(referenceFrame)
  assert(
    type(referenceFrame) == "table" and referenceFrame.width > 0,
    "FieldDialogueTheme.layout requires a reference frame"
  )
  local scale = referenceFrame.width / FieldDialogueTheme.referenceWidth
  local box = {
    x = FieldDialogueTheme.box.x,
    y = FieldDialogueTheme.box.y,
    width = FieldDialogueTheme.box.width,
    height = FieldDialogueTheme.box.height,
  }
  local text = {
    x = box.x + FieldDialogueTheme.textInsetX,
    y = box.y + FieldDialogueTheme.textInsetY,
    width = FieldDialogueTheme.textWidth,
    height = FieldDialogueTheme.textHeight,
  }
  return {
    scale = scale,
    origin = { x = referenceFrame.x, y = referenceFrame.y },
    box = box,
    text = text,
    cursor = {
      x = text.x + text.width - FieldDialogueTheme.cursor.width - FieldDialogueTheme.cursor.offsetX,
      y = text.y + text.height - FieldDialogueTheme.cursor.height - FieldDialogueTheme.cursor.offsetY,
      width = FieldDialogueTheme.cursor.width,
      height = FieldDialogueTheme.cursor.height,
    },
    lineHeight = FieldDialogueTheme.lineHeight,
  }
end

-- Maps a reference-space rect (as returned by layout) into screen pixels.

---@param layout FieldDialogueTheme.Layout
---@param rect FieldDialogueTheme.Rect
---@return FieldDialogueTheme.Rect
function FieldDialogueTheme.screenRect(layout, rect)
  assert(type(layout) == "table" and layout.origin and layout.scale, "screenRect requires a layout")
  assert(type(rect) == "table" and rect.x and rect.y and rect.width and rect.height, "screenRect requires a rect")
  return {
    x = layout.origin.x + rect.x * layout.scale,
    y = layout.origin.y + rect.y * layout.scale,
    width = rect.width * layout.scale,
    height = rect.height * layout.scale,
  }
end

-- The layout metrics object the paginator consumes: glyph advances from the
-- generated font definition, falling back to the compiled fallback glyph, and
-- the typeset width of marker tokens measured through the
-- same charmap the renderer draws them with. Returns a table with
-- glyphWidth(code) and nonGlyphWidth(token).

---@param fontDef FieldFontDef
---@return FieldDialogueTheme.Metrics
function FieldDialogueTheme.fontMetrics(fontDef)
  assert(
    type(fontDef) == "table" and type(fontDef.glyphs) == "table",
    "font metrics require a g4-field-font-v1 definition"
  )
  local function glyphAdvance(code)
    local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
    return glyph and glyph.advance or 0
  end
  return {
    glyphWidth = function(code)
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      return glyph and glyph.advance
    end,
    nonGlyphWidth = function(token)
      local text = FieldMessageText.tokensToText({ token })
      local measured = 0
      for i = 1, #text do
        local char = text:sub(i, i)
        local code = fontDef.charmap[char] or 0
        measured = measured + glyphAdvance(code) + (fontDef.letterSpacing or 0)
      end
      return measured
    end,
  }
end

-- Returns the field font's actual glyph-advance measurement for one text
-- string. Menu layout consumes this separately from dialogue token layout.
---@param fontDef FieldFontDef
---@return fun(text: string): number
function FieldDialogueTheme.measureText(fontDef)
  assert(
    type(fontDef) == "table" and type(fontDef.glyphs) == "table" and type(fontDef.charmap) == "table",
    "font text measurement requires a g4-field-font-v1 definition"
  )
  return function(text)
    assert(type(text) == "string", "text measurement requires a string")
    local measured = 0
    for i = 1, #text do
      local code = fontDef.charmap[text:sub(i, i)] or 0
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      measured = measured + (glyph and glyph.advance or 0) + (fontDef.letterSpacing or 0)
    end
    return measured
  end
end

-- Reference-canvas rectangle.

---@class FieldDialogueTheme.Rect
---@field x number
---@field y number
---@field width number
---@field height number

-- Reference-space geometry plus the single origin/scale mapping to the
-- viewport's reference frame.

---@class FieldDialogueTheme.Layout
---@field scale number
---@field origin { x: number, y: number }
---@field box FieldDialogueTheme.Rect
---@field text FieldDialogueTheme.Rect
---@field cursor FieldDialogueTheme.Rect
---@field lineHeight number

-- Metrics consumed by DialogueLayout: glyph advances and measured
-- non-glyph token widths.

---@class FieldDialogueTheme.Metrics
---@field glyphWidth fun(code: integer): integer?
---@field nonGlyphWidth fun(token: MessageToken): integer

return FieldDialogueTheme
