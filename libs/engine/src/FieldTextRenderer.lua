-- Shared presentation collaborator for authentic field text: the generated
-- HGSS field-font definition, its seven-band glyph atlas, and the
-- focus-indicator strip, plus the color-aware glyph quads (built lazily per
-- color band so plain color-0 UI never materializes variant quads), the
-- token-line and plain-string drawing operations, and the
-- drawFocusIndicator operation the dialogue, signpost, and Trainer Card
-- renderers all share. FieldState owns exactly one instance (a renderer
-- never acquires an independent atlas) and injects it; the renderer owns
-- the glyph atlas, the focus-indicator image, and their quad caches. Glyph
-- ink and shadow colors are baked at import time per band, so text draws at
-- identity tint; control tokens in a line draw nothing and take no width,
-- exactly as the paginator measured them -- the serialized marker spelling
-- is an editing contract, not presentation geometry. Glyph color is part of
-- the prepared token stream (colorIndex), never mutable renderer state.
-- Construction is failure-safe: a missing font atlas or focus-indicator
-- image is a typed error, and a quad or image failure after the atlas was
-- created releases every acquired image before rethrowing.

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
---@field _focusImage love.Image?
---@field _quads table<integer, table<integer, love.Quad>>? glyph quads per color band, band 0 built eagerly
---@field _focusQuads table<integer, love.Quad>? focus-indicator frame quads, built lazily
local FieldTextRenderer = {}
FieldTextRenderer.__index = FieldTextRenderer

-- opts.cacheFs: version-scoped private cache holding the compiled font def
-- and the atlas/focus PNGs; opts.graphics: injectable LÖVE graphics
-- namespace so tests can record draw calls; LÖVE itself remains an allowed
-- presentation-layer dependency (the atlas bytes still enter through
-- love.filesystem.newFileData).

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
  local fontDef = FieldFontLoader.load(opts.cacheFs, fontId)
  local self = setmetatable({
    fontDef = fontDef,
    _graphics = graphics,
    _atlas = nil,
    _quads = nil,
    _focusImage = nil,
    _focusQuads = nil,
  }, FieldTextRenderer)
  local data = opts.cacheFs:read(FieldFontCache.atlasPath(fontId))
  if not data then
    Errors.raise(
      FieldErrors.FONT_ATLAS_MISSING,
      "font atlas missing at " .. FieldFontCache.atlasPath(fontId),
      { fontId = fontId, path = FieldFontCache.atlasPath(fontId) }
    )
  end
  local focusPath = FieldFontCache.focusIndicatorsPath(fontId)
  local focusData = opts.cacheFs:read(focusPath)
  if not focusData then
    Errors.raise(FieldErrors.FONT_FOCUS_IMAGE_MISSING, "focus indicator strip missing at " .. focusPath, {
      fontId = fontId,
      path = focusPath,
    })
  end
  local ok, err = pcall(function()
    self._atlas = graphics.newImage(love.filesystem.newFileData(data, FieldFontCache.atlasPath(fontId)))
    self._atlas:setFilter("nearest", "nearest")
    self:_buildQuads()
    self._focusImage = graphics.newImage(love.filesystem.newFileData(focusData, focusPath))
    self._focusImage:setFilter("nearest", "nearest")
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The base-band glyph quads, built eagerly: every plain drawText and
-- color-0 line starts from this cache, while higher bands stay lazy so
-- ordinary color-0 UI never materializes variant quads.
function FieldTextRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local width, height = atlas:getWidth(), atlas:getHeight()
  local quads = {}
  for code, glyph in pairs(self.fontDef.glyphs) do
    quads[code] = lg.newQuad(glyph.x, glyph.y, glyph.w, glyph.h, width, height)
  end
  self._quads = { [0] = quads }
end

-- The quad of one glyph in one color band: variant y = glyph.y +
-- colorIndex * colorVariants.strideY, geometry identical across bands.
-- Built lazily per (band, code) pair; an out-of-range color index fails
-- loudly instead of clamping to the base band.
---@param colorIndex integer
---@param code integer
---@return love.Quad
function FieldTextRenderer:_quad(colorIndex, code)
  if
    type(colorIndex) ~= "number"
    or colorIndex % 1 ~= 0
    or colorIndex < 0
    or colorIndex >= FieldMessageText.COLOR_VARIANT_COUNT
  then
    Errors.raise(
      FieldErrors.FONT_COLOR_INDEX_INVALID,
      "glyph color index "
        .. tostring(colorIndex)
        .. " is outside 0.."
        .. tostring(FieldMessageText.COLOR_VARIANT_COUNT - 1),
      { colorIndex = colorIndex }
    )
  end
  local byColor = self._quads[colorIndex]
  if not byColor then
    byColor = {}
    self._quads[colorIndex] = byColor
  end
  local quad = byColor[code]
  if quad then
    return quad
  end
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local glyph = self.fontDef.glyphs[code] or self.fontDef.glyphs[0]
  quad = lg.newQuad(
    glyph.x,
    glyph.y + colorIndex * self.fontDef.colorVariants.strideY,
    glyph.w,
    glyph.h,
    atlas:getWidth(),
    atlas:getHeight()
  )
  byColor[code] = quad
  return quad
end

-- Draws one page line at the reference-canvas position: glyphs through the
-- atlas band named by the prepared colorIndex at identity tint (the
-- compiled ink/shadow/background colors are baked). Control tokens draw
-- nothing and take no width, matching the paginator's widthless
-- measurement, so following glyphs start exactly where layout placed them
-- and no diagnostic text ever appears in production presentation.

---@param tokens MessageToken[]
---@param x number
---@param y number
function FieldTextRenderer:drawLine(tokens, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local def = self.fontDef
  local letterSpacing = def.letterSpacing or 0
  lg.setColor(1, 1, 1, 1)
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local quad = self:_quad(token.colorIndex or 0, token.code)
      lg.draw(atlas, quad, x, y)
      local glyph = def.glyphs[token.code] or def.glyphs[0]
      x = x + glyph.advance + letterSpacing
    end
  end
end

-- Draws one plain text string at the reference-canvas position (the audited
-- card labels/values path), glyph by glyph at identity tint on the base
-- color band.

---@param text string
---@param x number
---@param y number
function FieldTextRenderer:drawText(text, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local def = self.fontDef
  for char in Utf8Glyphs.iter(text) do
    local code = def.charmap[char]
    if not code then
      code = 0
    end
    local glyph = def.glyphs[code] or def.glyphs[0]
    local quad = self:_quad(0, code)
    lg.draw(atlas, quad, x, y)
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

-- The field index of the last focus_indicator token visible in source
-- order, or nil when none is visible. The one authoritative last-wins scan
-- the window renderers use: several visible controls draw one frame.
-- Prepared tokens always carry exactly one frame argument.
---@param visibleLines MessageToken[][]
---@return integer?
function FieldTextRenderer.lastVisibleFocusField(visibleLines)
  local field
  for _, line in ipairs(visibleLines) do
    for _, token in ipairs(line) do
      if token.kind == "focus_indicator" then
        field = token.args[1]
      end
    end
  end
  return field
end

-- Draws the source screen-focus indicator frame (the YESNO printer control
-- graphic) at the caller's position: the imported 24x32 frame rect of the
-- requested field at identity tint. The method owns no placement decision --
-- window-specific renderers place the indicator at their content edges. An
-- out-of-range field fails loudly instead of clamping.
---@param field integer
---@param x number
---@param y number
function FieldTextRenderer:drawFocusIndicator(field, x, y)
  if type(field) ~= "number" or field % 1 ~= 0 or field < 0 or field >= FieldMessageText.FOCUS_INDICATOR_COUNT then
    Errors.raise(
      FieldErrors.FONT_FOCUS_FIELD_INVALID,
      "focus indicator field "
        .. tostring(field)
        .. " is outside 0.."
        .. tostring(FieldMessageText.FOCUS_INDICATOR_COUNT - 1),
      { field = field }
    )
  end
  local lg = assert(self._graphics)
  local focusImage = assert(self._focusImage)
  local rect = self.fontDef.focusIndicators.frames[field]
  local quads = self._focusQuads or {}
  local quad = quads[field]
  if quad == nil then
    quad = lg.newQuad(rect.x, rect.y, rect.width, rect.height, focusImage:getWidth(), focusImage:getHeight())
    quads[field] = quad
    self._focusQuads = quads
  end
  lg.setColor(1, 1, 1, 1)
  lg.draw(focusImage, quad, x, y)
end

function FieldTextRenderer:release()
  if self._atlas and self._atlas.release then
    self._atlas:release()
  end
  if self._focusImage and self._focusImage.release then
    self._focusImage:release()
  end
  self._atlas, self._quads = nil, nil
  self._focusImage, self._focusQuads = nil, nil
end

return FieldTextRenderer
