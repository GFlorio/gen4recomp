-- Renders the modal dialogue box into the viewport's centered 4:3 reference
-- frame: a provisional nine-slice window, the extracted
-- glyph atlas text (ink and shadow baked at import time), and a blinking
-- continue cursor. It owns the font definition and atlas Image, builds the
-- slice source image once, draws after the 3D world pass, and restores every
-- graphics state it touches (canvas, shader, scissor, blend, depth, color).
-- Pure-free by design: nothing else may own the atlas.
-- Construction is failure-safe: a quad/slice failure after the atlas or slice
-- image was created releases the acquired images before rethrowing, and draw()
-- balances its transform push even when drawing raises.

local Errors = require("libs.rom.src.Errors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

---@class FieldDialogueRenderer
---@field _cacheFs CacheFs
---@field _theme FieldDialogueTheme
---@field _graphics love.Graphics?
---@field fontId integer
---@field fontDef FieldFontDef
---@field atlas love.Image?
---@field _quads table<integer, love.Quad>?
---@field _sliceImage love.Image?
---@field _sliceQuads love.Quad[]?
local FieldDialogueRenderer = {}
FieldDialogueRenderer.__index = FieldDialogueRenderer

-- Provisional nine-slice drawn from a 6x6 source image: 2px border ring and a
-- stretchable center, nearest-filtered so scaled edges never seam.
local SLICE_BORDER = 2

-- opts.cacheFs: version-scoped private cache holding the compiled font def
-- and atlas PNG; opts.graphics: injectable LÖVE graphics namespace (nil keeps
-- the module headless with the definition only); opts.theme: geometry record.

---@param opts { cacheFs: CacheFs, fontId?: integer, theme?: FieldDialogueTheme, graphics?: love.Graphics? }
---@return FieldDialogueRenderer
function FieldDialogueRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.loadLua,
    "FieldDialogueRenderer requires a CacheFs-shaped object"
  )
  local fontId = opts.fontId or 0
  local theme = opts.theme or FieldDialogueTheme
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  local cacheFs = opts.cacheFs

  local def = FieldFontLoader.load(cacheFs, fontId)

  local self = setmetatable({
    _cacheFs = cacheFs,
    _theme = theme,
    _graphics = graphics,
    fontId = fontId,
    fontDef = def,
    atlas = nil,
    _quads = nil,
    _sliceImage = nil,
    _sliceQuads = nil,
  }, FieldDialogueRenderer)

  if graphics and graphics.newImage then
    local data = cacheFs:read(FieldFontCache.atlasPath(fontId))
    if not data then
      Errors.raise(
        "FONT_ATLAS_MISSING",
        "font atlas missing at " .. FieldFontCache.atlasPath(fontId),
        { fontId = fontId, path = FieldFontCache.atlasPath(fontId) }
      )
    end
    self.atlas = graphics.newImage(love.filesystem.newFileData(data, FieldFontCache.atlasPath(fontId)))
    local ok, err = pcall(function()
      self.atlas:setFilter("nearest", "nearest")
      self:_buildQuads()
      self:_buildSlice()
    end)
    if not ok then
      self:release()
      error(err)
    end
  end
  return self
end

function FieldDialogueRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local atlas = assert(self.atlas)
  local width, height = atlas:getWidth(), atlas:getHeight()
  local quads = {}
  for code, glyph in pairs(self.fontDef.glyphs) do
    quads[code] = lg.newQuad(glyph.x, glyph.y, glyph.w, glyph.h, width, height)
  end
  self._quads = quads
end

-- The 6x6 slice source: 2px border ring (border color) around a stretchable
-- center (window fill). Quads are split at the 2/4 grid lines.
function FieldDialogueRenderer:_buildSlice()
  local lg = assert(self._graphics)
  local colors = self._theme.colors
  local size = self._theme.slice.size
  local imageData = love.image.newImageData(size, size)
  local border, fill = colors.border, colors.fill
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local onBorder = x < SLICE_BORDER or y < SLICE_BORDER or x >= size - SLICE_BORDER or y >= size - SLICE_BORDER
      local c = onBorder and border or fill
      imageData:setPixel(x, y, c[1], c[2], c[3], c[4])
    end
  end
  self._sliceImage = lg.newImage(imageData)
  self._sliceImage:setFilter("nearest", "nearest")
  local quads = {}
  local index = 0
  for row = 0, 2 do
    local sy = row * SLICE_BORDER
    local sh = row < 2 and SLICE_BORDER or size - 2 * SLICE_BORDER
    for col = 0, 2 do
      local sx = col * SLICE_BORDER
      local sw = col < 2 and SLICE_BORDER or size - 2 * SLICE_BORDER
      index = index + 1
      quads[index] = lg.newQuad(sx, sy, sw, sh, size, size)
    end
  end
  self._sliceQuads = quads
end

-- Converts marker text to glyph runs through the compiled charmap.
-- Characters without a glyph render the compiled fallback glyph; marker text
-- is provisional developer aid, never silently dropped.

---@param text string
---@return FieldDialogueRenderer.GlyphRun[]
function FieldDialogueRenderer:_glyphRuns(text)
  local runs = {}
  for i = 1, #text do
    local char = text:sub(i, i)
    local code = self.fontDef.charmap[char]
    if not code then
      code = 0
    end
    local glyph = self.fontDef.glyphs[code] or self.fontDef.glyphs[0]
    runs[#runs + 1] = {
      quad = self._quads[code],
      advance = glyph.advance + (self.fontDef.letterSpacing or 0),
    }
  end
  return runs
end

-- Draws one marker token's text (substitution/style/wait/unsupported) in the
-- marker color. Marker text keeps its measured layout width, so it never
-- overlaps the following glyphs; the color makes it unmistakably a marker.

---@param tokens MessageToken[]
---@param x number
---@param y number
---@param advanceX number[]
function FieldDialogueRenderer:_drawMarkerTokens(tokens, x, y, advanceX)
  local lg = assert(self._graphics)
  local atlas = assert(self.atlas)
  local color = self._theme.colors.marker
  lg.setColor(color[1], color[2], color[3], color[4])
  for _, token in ipairs(tokens) do
    local runs = self:_glyphRuns(FieldMessageText.tokensToText({ token }))
    for _, run in ipairs(runs) do
      if run.quad then
        lg.draw(self.atlas, run.quad, x, y)
      end
      x = x + run.advance
    end
    advanceX[1] = x
  end
end

-- Draws one page line at the reference-canvas position: glyphs through the
-- atlas (identity tint: the compiled ink/shadow/background colors are baked),
-- non-glyph tokens as compact markers.

---@param tokens MessageToken[]
---@param x number
---@param y number
function FieldDialogueRenderer:_drawLine(tokens, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self.atlas)
  local advanceX = { x }
  local markers = {}
  lg.setColor(1, 1, 1, 1)
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      self:_flushMarkers(markers, advanceX, y)
      local quad = self._quads[token.code] or self._quads[0]
      if quad then
        lg.draw(atlas, quad, advanceX[1], y)
      end
      local glyph = self.fontDef.glyphs[token.code] or self.fontDef.glyphs[0]
      advanceX[1] = advanceX[1] + glyph.advance + (self.fontDef.letterSpacing or 0)
    else
      markers[#markers + 1] = token
    end
  end
  self:_flushMarkers(markers, advanceX, y)
end

---@param markers MessageToken[]
---@param advanceX number[]
---@param y number
function FieldDialogueRenderer:_flushMarkers(markers, advanceX, y)
  if #markers == 0 then
    return
  end
  self:_drawMarkerTokens(markers, advanceX[1], y, advanceX)
  for i = 1, #markers do
    markers[i] = nil
  end
end

-- Draws the continue cursor at the text area's bottom-right while the
-- controller waits at a boundary, using the controller's deterministic blink.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueTheme.Layout
function FieldDialogueRenderer:_drawCursor(status, layout)
  if not status.waiting or not status.cursorOn then
    return
  end
  local lg = assert(self._graphics)
  local cursor = layout.cursor
  local color = self._theme.colors.cursor
  lg.setColor(color[1], color[2], color[3], color[4])
  lg.polygon(
    "fill",
    cursor.x,
    cursor.y,
    cursor.x + cursor.width,
    cursor.y,
    cursor.x + cursor.width / 2,
    cursor.y + cursor.height
  )
end

-- Draws the window nine-slice over the box rect in reference coordinates.
-- Each slice quad is SLICE_BORDER source pixels; LÖVE scale factors are
-- destination-size / source-size, so dividing by SLICE_BORDER keeps the
-- center at box.width-2*edge instead of doubling it.

---@param layout FieldDialogueTheme.Layout
function FieldDialogueRenderer:_drawBox(layout)
  local lg = assert(self._graphics)
  local sliceImage = assert(self._sliceImage)
  local sliceQuads = assert(self._sliceQuads)
  local box = layout.box
  local spansX = { box.x, box.x + SLICE_BORDER, box.x + box.width - SLICE_BORDER }
  local spansY = { box.y, box.y + SLICE_BORDER, box.y + box.height - SLICE_BORDER }
  local widths = { SLICE_BORDER, box.width - 2 * SLICE_BORDER, SLICE_BORDER }
  local heights = { SLICE_BORDER, box.height - 2 * SLICE_BORDER, SLICE_BORDER }
  local index = 0
  for row = 1, 3 do
    for col = 1, 3 do
      index = index + 1
      lg.draw(
        sliceImage,
        sliceQuads[index],
        spansX[col],
        spansY[row],
        0,
        widths[col] / SLICE_BORDER,
        heights[row] / SLICE_BORDER
      )
    end
  end
end

-- Draws the dialogue into viewport.referenceFrame. No-op (and no state
-- touched) when the controller is closed or this renderer has no atlas.
-- Restores canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally.

---@param controller FieldDialogueController
---@param viewport { referenceFrame: FieldDialogueTheme.Rect }
function FieldDialogueRenderer:draw(controller, viewport)
  if not controller or not controller:isModal() or not self.atlas then
    return
  end
  local lg = assert(self._graphics)
  local status = controller:status()

  local canvas = lg.getCanvas()
  local shader = lg.getShader()
  local blendMode, blendAlpha = lg.getBlendMode()
  local depthMode, depthWrite = lg.getDepthMode()
  local wireframe = lg.isWireframe()
  local cullMode = lg.getMeshCullMode()
  local color = { lg.getColor() }
  local scissorX, scissorY, scissorW, scissorH = lg.getScissor()

  local pushed = false
  local ok, err = pcall(function()
    -- Everything draws in reference-canvas coordinates under one
    -- translate(origin) + scale transform; the theme never returns
    -- screen-mapped rects, so nothing is scaled twice.
    local layout = self._theme.layout(viewport.referenceFrame)
    lg.push()
    pushed = true
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    lg.setColor(1, 1, 1, 1)
    self:_drawBox(layout)
    local lineY = layout.text.y
    for _, tokens in ipairs(status.visibleLines) do
      self:_drawLine(tokens, layout.text.x, lineY)
      lineY = lineY + layout.lineHeight
    end
    self:_drawCursor(status, layout)
    lg.pop()
    pushed = false
  end)

  -- Finally-style cleanup: a draw error must not leave the transform stack
  -- unbalanced for the caller's next frame.
  if pushed then
    lg.pop()
  end

  lg.setCanvas(canvas)
  lg.setShader(shader)
  if blendMode then
    lg.setBlendMode(blendMode, blendAlpha)
  end
  if depthMode then
    lg.setDepthMode(depthMode, depthWrite)
  end
  lg.setWireframe(wireframe)
  if cullMode then
    lg.setMeshCullMode(cullMode)
  end
  lg.setColor(color[1], color[2], color[3], color[4])
  if scissorX then
    lg.setScissor(scissorX, scissorY, scissorW, scissorH)
  else
    lg.setScissor()
  end

  if not ok then
    error(err)
  end
end

function FieldDialogueRenderer:release()
  if self.atlas and self.atlas.release then
    self.atlas:release()
  end
  if self._sliceImage and self._sliceImage.release then
    self._sliceImage:release()
  end
  self.atlas, self._sliceImage = nil, nil
  self._quads, self._sliceQuads = nil, nil
end

-- One positioned glyph of marker text: the atlas quad and the advance to the
-- next run.

---@class FieldDialogueRenderer.GlyphRun
---@field quad love.Quad?
---@field advance number

return FieldDialogueRenderer
