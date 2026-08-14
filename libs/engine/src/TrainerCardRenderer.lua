-- Renders the authentic HGSS Trainer Card front into the viewport's centered
-- 4:3 reference frame: the generated card art (the manifest's
-- `hgss.trainer_card.front` asset at its front rect) plus the audited front
-- text layout from ov51_021E6F18 in asm/overlay_trainer_card_main.s at the
-- pinned decomp commit 008257708 — the front windows created from the
-- template table at 0x021E7F48 (8px/tile) and the label/value prints of the
-- source function. The front labels ("ID No.", "NAME", "MONEY", "SCORE",
-- "TIME", "ADVENTURE STARTED") are the fixed card layout (msgdata bank 727
-- messages 0..6); the player name is right-aligned to x=240 and the trainer
-- id (five digits, zero-padded per the source's String16_FormatInteger)
-- right-aligned to x=112 on the y=24 row. Every value the §29.1 model does
-- not own (money/play time/badges/pokedex/stars/signature) renders the
-- audited blank presentation: the label rows stay empty and the POKéDEX row
-- (source-gated) is not drawn at all, so nothing is fabricated. The bottom
-- band below the last text row is the reserved signature region (§27): the
-- renderer never draws there and exposes the reservation as a named record
-- so the future editor needs no redesign. Construction is failure-safe: a
-- missing manifest, font, or card front is a typed error, a quad failure
-- after the images were created releases them before rethrowing, and draw()
-- restores every graphics state it touches.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")

---@class TrainerCardRenderer
---@field _graphics love.Graphics
---@field _fontDef FieldFontDef
---@field _atlas love.Image?
---@field _quads table<integer, love.Quad>?
---@field _cardImage love.Image?
---@field _cardQuad love.Quad?
---@field card { front: FieldDialogueTheme.Rect } the resolved manifest front surface
local TrainerCardRenderer = {}
TrainerCardRenderer.__index = TrainerCardRenderer

-- The audited front text anchors (canonical 256x192 reference space): the
-- label origin of each front window (template table 0x021E7F48) and the
-- right edge of each right-aligned value print in ov51_021E6F18.
TrainerCardRenderer.LABEL_ANCHORS = {
  { text = "ID No.", x = 16, y = 24 },
  { text = "NAME", x = 136, y = 24 },
  { text = "MONEY", x = 16, y = 48 },
  { text = "SCORE", x = 16, y = 104 },
  { text = "TIME", x = 16, y = 128 },
  { text = "ADVENTURE STARTED", x = 16, y = 144 },
}
TrainerCardRenderer.NAME_RIGHT_EDGE = 240
TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE = 112
TrainerCardRenderer.TRAINER_ID_DIGITS = 5

-- The signature display reservation (§27): the bottom band of the card front
-- below the last audited text row (y=160). The renderer never draws in it;
-- the future signature editor owns this region.
TrainerCardRenderer.SIGNATURE_REGION = { x = 0, y = 160, width = 256, height = 32 }

-- opts.cacheFs: version-scoped private cache holding the compiled font def,
-- the font atlas PNG, and the generated field-UI class (manifest + card
-- front PNG); opts.graphics: injectable LÖVE graphics namespace.

---@param opts { cacheFs: CacheFs, graphics?: love.Graphics? }
---@return TrainerCardRenderer
function TrainerCardRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.loadLua,
    "TrainerCardRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "TrainerCardRenderer requires love.graphics")
  local cacheFs = opts.cacheFs

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the card front PNG and its rect. The runtime boot already validates
  -- the full manifest; the renderer resolves what it draws.
  local manifest = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if type(manifest) ~= "table" then
    Errors.raise(
      FieldErrors.FIELD_UI_MANIFEST_MISSING,
      "field UI manifest missing at " .. FieldUiAssetCache.manifestPath(),
      { path = FieldUiAssetCache.manifestPath() }
    )
  end
  local uiManifest = manifest --[[@as table]]
  local trainerCard = uiManifest.trainerCard
  local frontAsset = uiManifest.assets and uiManifest.assets["hgss.trainer_card.front"]
  if
    type(trainerCard) ~= "table"
    or type(trainerCard.front) ~= "table"
    or type(frontAsset) ~= "table"
    or type(frontAsset.image) ~= "string"
  then
    Errors.raise(FieldErrors.FIELD_UI_MANIFEST_INVALID, "field UI manifest has no trainer card front surface", {})
  end

  local self = setmetatable({
    _graphics = graphics,
    _fontDef = nil,
    _atlas = nil,
    _quads = nil,
    _cardImage = nil,
    _cardQuad = nil,
    card = {
      front = trainerCard.front,
    },
  }, TrainerCardRenderer)

  -- The font definition loads before any image is acquired; the atlas is
  -- created next, and every later failure (missing card front, quad failure)
  -- releases what was already acquired exactly once.
  self._fontDef = FieldFontLoader.load(cacheFs, 0)
  local atlasData = cacheFs:read(FieldFontCache.atlasPath(0))
  if not atlasData then
    Errors.raise(
      FieldErrors.FONT_ATLAS_MISSING,
      "font atlas missing at " .. FieldFontCache.atlasPath(0),
      { fontId = 0, path = FieldFontCache.atlasPath(0) }
    )
  end
  local cardPath = frontAsset.image
  local cardData = cacheFs:read(cardPath)
  local ok, err = pcall(function()
    self._atlas = graphics.newImage(love.filesystem.newFileData(atlasData, FieldFontCache.atlasPath(0)))
    self._atlas:setFilter("nearest", "nearest")
    if not cardData then
      self:release()
      Errors.raise(FieldErrors.FIELD_UI_TRAINER_CARD_FRONT_MISSING, "trainer card front missing at " .. cardPath, {
        path = cardPath,
      })
    end
    self._cardImage = graphics.newImage(love.filesystem.newFileData(cardData, cardPath))
    self._cardImage:setFilter("nearest", "nearest")
    self:_buildQuads()
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The quads are the manifest rects inside their atlases: one glyph quad per
-- font glyph and one for the card front surface.
function TrainerCardRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local width, height = atlas:getWidth(), atlas:getHeight()
  local quads = {}
  for code, glyph in pairs(self._fontDef.glyphs) do
    quads[code] = lg.newQuad(glyph.x, glyph.y, glyph.w, glyph.h, width, height)
  end
  self._quads = quads
  local card = assert(self._cardImage)
  local rect = self.card.front
  self._cardQuad = lg.newQuad(rect.x, rect.y, rect.width, rect.height, card:getWidth(), card:getHeight())
end

-- The measured width of one text string in the generated field font (the
-- source's FontID_String_GetWidth equivalent): the sum of the glyph advances.
---@param text string
---@return number
function TrainerCardRenderer:_textWidth(text)
  local def = assert(self._fontDef, "the trainer card renderer requires the font definition")
  local width = 0
  for i = 1, #text do
    local code = def.charmap[text:sub(i, i)]
    if not code then
      code = 0
    end
    local glyph = def.glyphs[code] or def.glyphs[0]
    width = width + glyph.advance + (def.letterSpacing or 0)
  end
  return width
end

-- Draws one text string at the reference-canvas position through the glyph
-- atlas at identity tint (the compiled ink/shadow colors are baked).
---@param text string
---@param x number
---@param y number
function TrainerCardRenderer:_drawText(text, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas, "the trainer card renderer is disposed")
  local def = assert(self._fontDef)
  local quads = assert(self._quads)
  for i = 1, #text do
    local code = def.charmap[text:sub(i, i)]
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

-- Draws the canonical card front into viewport.referenceFrame: the card art
-- over the manifest front rect, then the audited labels and the two
-- authoritative values (right-aligned per the source prints). The optional
-- model fields are nil in every current profile, so their rows render the
-- authentic blank presentation; nothing is drawn inside the reserved
-- signature region. No-op (and no state touched) when this renderer has no
-- images. Restores canvas, shader, scissor, blend, depth, wireframe, cull,
-- and color afterwards.

---@param presentation table?
---@param viewport { referenceFrame: FieldDialogueTheme.Rect }
function TrainerCardRenderer:draw(presentation, viewport)
  if not presentation or not self._cardImage then
    return
  end
  local lg = assert(self._graphics)
  assert(type(presentation.name) == "string", "the card presentation requires the player name")
  assert(type(presentation.trainerId) == "number", "the card presentation requires the trainer id")

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
    local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
    lg.push()
    pushed = true
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    lg.setColor(1, 1, 1, 1)
    lg.draw(assert(self._cardImage), assert(self._cardQuad), self.card.front.x, self.card.front.y)
    for _, anchor in ipairs(TrainerCardRenderer.LABEL_ANCHORS) do
      self:_drawText(anchor.text, anchor.x, anchor.y)
    end
    local name = presentation.name
    self:_drawText(name, TrainerCardRenderer.NAME_RIGHT_EDGE - self:_textWidth(name), 24)
    local trainerId = string.format("%0" .. TrainerCardRenderer.TRAINER_ID_DIGITS .. "d", presentation.trainerId)
    self:_drawText(trainerId, TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE - self:_textWidth(trainerId), 24)
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

function TrainerCardRenderer:release()
  if self._atlas and self._atlas.release then
    self._atlas:release()
  end
  if self._cardImage and self._cardImage.release then
    self._cardImage:release()
  end
  self._atlas, self._cardImage = nil, nil
  self._quads, self._cardQuad = nil, nil
end

return TrainerCardRenderer
