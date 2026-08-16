-- Shared presentation collaborator for authentic field text: the generated
-- HGSS field-font definition, its glyph atlas, and the glyph quads, plus
-- the token-line and plain-string drawing operations the dialogue, signpost,
-- and Trainer Card renderers all need. FieldState owns exactly one instance
-- (a renderer never acquires an independent atlas) and injects it; the
-- renderer owns only its own frame/card images. Glyph ink and shadow colors
-- are baked at import time, so text draws at identity tint; control tokens
-- in a line draw nothing and take no width, exactly as the paginator
-- measured them -- the serialized marker spelling is an editing contract,
-- not presentation geometry. Construction is
-- failure-safe: a missing font atlas is a typed error, and a quad failure
-- after the image was created releases it before rethrowing.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class FieldTextRenderer
---@field fontDef FieldFontDef
---@field _graphics love.Graphics
---@field _atlas love.Image?
---@field _quads table<integer, love.Quad>?
local FieldTextRenderer = {}
FieldTextRenderer.__index = FieldTextRenderer

-- opts.cacheFs: version-scoped private cache holding the compiled font def
-- and atlas PNG; opts.graphics: injectable LÖVE graphics namespace so tests
-- can record draw calls; LÖVE itself remains an allowed presentation-layer
-- dependency (the atlas bytes still enter through love.filesystem.newFileData).

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

-- Draws one page line at the reference-canvas position: glyphs through the
-- atlas at identity tint (the compiled ink/shadow/background colors are
-- baked). Control tokens draw nothing and take no width, matching the
-- paginator's widthless measurement, so following glyphs start exactly where
-- layout placed them and no diagnostic text ever appears in production
-- presentation.

---@param tokens MessageToken[]
---@param x number
---@param y number
function FieldTextRenderer:drawLine(tokens, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local quads = assert(self._quads)
  local def = self.fontDef
  local letterSpacing = def.letterSpacing or 0
  lg.setColor(1, 1, 1, 1)
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local quad = quads[token.code] or quads[0]
      if quad then
        lg.draw(atlas, quad, x, y)
      end
      local glyph = def.glyphs[token.code] or def.glyphs[0]
      x = x + glyph.advance + letterSpacing
    end
  end
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
