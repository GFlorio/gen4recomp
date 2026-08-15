-- Shared presentation collaborator for authentic field text: the generated
-- HGSS field-font definition, its glyph atlas, and the glyph quads, plus
-- the token-line and plain-string drawing operations the dialogue, signpost,
-- and Trainer Card renderers all need. FieldState owns exactly one instance
-- (a renderer never acquires an independent atlas) and injects it; the
-- renderer owns only its own frame/card images. Glyph ink and shadow colors
-- are baked at import time, so text draws at identity tint; non-glyph tokens
-- render as compact developer-aid markers that keep their measured layout
-- width, never silently dropped. Construction is failure-safe: a missing
-- font atlas is a typed error, and a quad failure after the image was
-- created releases it before rethrowing.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldMessageText = require("libs.assets.src.FieldMessageText")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class FieldTextRenderer
---@field fontDef FieldFontDef
---@field _graphics love.Graphics
---@field _atlas love.Image?
---@field _quads table<integer, love.Quad>?
local FieldTextRenderer = {}
FieldTextRenderer.__index = FieldTextRenderer

-- Developer-aid marker color for non-glyph tokens, matching the aid color of
-- the dialogue theme.
FieldTextRenderer.MARKER_COLOR = { 0.55, 0.25, 0.10, 1 }

-- opts.cacheFs: version-scoped private cache holding the compiled font def
-- and atlas PNG; opts.graphics: injectable LÖVE graphics namespace.

---@param opts { cacheFs: CacheFs, fontId?: integer, graphics?: love.Graphics? }
---@return FieldTextRenderer
function FieldTextRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldTextRenderer requires a CacheFs-shaped object"
  )
  local fontId = opts.fontId or 0
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldTextRenderer requires love.graphics")
  local self = setmetatable({
    fontDef = FieldFontLoader.load(opts.cacheFs, fontId),
    _graphics = graphics,
    _atlas = nil,
    _quads = nil,
  }, FieldTextRenderer)
  local data = opts.cacheFs:read(FieldFontCache.atlasPath(fontId))
  if not data then
    Errors.raise(
      FieldErrors.FONT_ATLAS_MISSING,
      "font atlas missing at " .. FieldFontCache.atlasPath(fontId),
      { fontId = fontId, path = FieldFontCache.atlasPath(fontId) }
    )
  end
  local ok, err = pcall(function()
    self._atlas = graphics.newImage(love.filesystem.newFileData(data, FieldFontCache.atlasPath(fontId)))
    self._atlas:setFilter("nearest", "nearest")
    self:_buildQuads()
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

function FieldTextRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local width, height = atlas:getWidth(), atlas:getHeight()
  local quads = {}
  for code, glyph in pairs(self.fontDef.glyphs) do
    quads[code] = lg.newQuad(glyph.x, glyph.y, glyph.w, glyph.h, width, height)
  end
  self._quads = quads
end

-- Converts marker text to glyph runs through the compiled charmap.
-- Characters without a glyph render the compiled fallback glyph; marker text
-- is developer aid, never silently dropped.

---@param text string
---@return { quad: love.Quad?, advance: number }[]
function FieldTextRenderer:_glyphRuns(text)
  local runs = {}
  for char in Utf8Glyphs.iter(text) do
    local code = self.fontDef.charmap[char]
    if not code then
      code = 0
    end
    local glyph = self.fontDef.glyphs[code] or self.fontDef.glyphs[0]
    runs[#runs + 1] = {
      quad = assert(self._quads)[code],
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
function FieldTextRenderer:_drawMarkerTokens(tokens, x, y, advanceX)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local color = FieldTextRenderer.MARKER_COLOR
  lg.setColor(color[1], color[2], color[3], color[4])
  for _, token in ipairs(tokens) do
    local runs = self:_glyphRuns(FieldMessageText.tokensToText({ token }))
    for _, run in ipairs(runs) do
      if run.quad then
        lg.draw(atlas, run.quad, x, y)
      end
      x = x + run.advance
    end
    advanceX[1] = x
  end
end

---@param markers MessageToken[]
---@param advanceX number[]
---@param y number
function FieldTextRenderer:_flushMarkers(markers, advanceX, y)
  if #markers == 0 then
    return
  end
  self:_drawMarkerTokens(markers, advanceX[1], y, advanceX)
  for i = 1, #markers do
    markers[i] = nil
  end
end

-- Draws one page line at the reference-canvas position: glyphs through the
-- atlas (identity tint: the compiled ink/shadow/background colors are baked),
-- non-glyph tokens as compact markers.

---@param tokens MessageToken[]
---@param x number
---@param y number
function FieldTextRenderer:drawLine(tokens, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local quads = assert(self._quads)
  local advanceX = { x }
  local markers = {}
  lg.setColor(1, 1, 1, 1)
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      self:_flushMarkers(markers, advanceX, y)
      local quad = quads[token.code] or quads[0]
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

-- Draws one plain text string at the reference-canvas position (the audited
-- card labels/values path), glyph by glyph at identity tint.

---@param text string
---@param x number
---@param y number
function FieldTextRenderer:drawText(text, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local quads = assert(self._quads)
  local def = self.fontDef
  for char in Utf8Glyphs.iter(text) do
    local code = def.charmap[char]
    if not code then
      code = 0
    end
    local glyph = def.glyphs[code] or def.glyphs[0]
    local quad = quads[code] or quads[0]
    if quad then
      lg.draw(atlas, quad, x, y)
    end
    x = x + glyph.advance + (def.letterSpacing or 0)
  end
end

-- The measured width of one text string in the generated field font (the
-- source's FontID_String_GetWidth equivalent): the sum of the glyph advances.
---@param text string
---@return number
function FieldTextRenderer:textWidth(text)
  local def = self.fontDef
  local width = 0
  for char in Utf8Glyphs.iter(text) do
    local code = def.charmap[char]
    if not code then
      code = 0
    end
    local glyph = def.glyphs[code] or def.glyphs[0]
    width = width + glyph.advance + (def.letterSpacing or 0)
  end
  return width
end

function FieldTextRenderer:release()
  if self._atlas and self._atlas.release then
    self._atlas:release()
  end
  self._atlas, self._quads = nil, nil
end

return FieldTextRenderer
