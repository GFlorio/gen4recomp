-- Renders the modal dialogue box into the viewport's centered 4:3 reference
-- frame: the authentic HGSS user-frame strip (the player's selected frame
-- index resolved from the generated field-UI manifest and drawn by the
-- DrawFrameAndWindow2 tilemap), the extracted glyph atlas text (ink and
-- shadow baked at import time), and a blinking continue cursor. It owns the
-- font definition, the font atlas, and the frame strip Images; builds glyph
-- quads once and frame quads lazily per frame index; draws after the 3D
-- world pass; and restores every graphics state it touches (canvas, shader,
-- scissor, blend, depth, color). Presentation-only by design: FieldFontLoader
-- owns runtime font definitions and the generated manifest owns frame rects.
-- Construction is failure-safe: a missing manifest or frame strip is a typed
-- error, a quad failure after the images were created releases the acquired
-- images before rethrowing, and draw() balances its transform push even when
-- drawing raises.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

---@class FieldDialogueRenderer
---@field _cacheFs CacheFs
---@field _theme FieldDialogueTheme
---@field _graphics love.Graphics
---@field fontId integer
---@field fontDef FieldFontDef
---@field atlas love.Image?
---@field _quads table<integer, love.Quad>?
---@field _manifest table|nil the generated field-UI manifest
---@field _frameImage love.Image?
---@field _frameQuadCache table<integer, love.Quad[]>|nil per-frame tile quads, built lazily
local FieldDialogueRenderer = {}
FieldDialogueRenderer.__index = FieldDialogueRenderer

-- opts.cacheFs: version-scoped private cache holding the compiled font def,
-- the font atlas PNG, and the generated field-UI class (manifest + frame
-- strip); opts.graphics: injectable LÖVE graphics namespace; opts.theme:
-- geometry record.

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
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldDialogueRenderer requires love.graphics")
  local cacheFs = opts.cacheFs

  local def = FieldFontLoader.load(cacheFs, fontId)

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the frame strip and every frame's tile rects. The runtime boot
  -- already validates the full manifest; the renderer resolves what it draws.
  local manifest = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if type(manifest) ~= "table" then
    Errors.raise(
      "FIELD_UI_MANIFEST_MISSING",
      "field UI manifest missing at " .. FieldUiAssetCache.manifestPath(),
      { path = FieldUiAssetCache.manifestPath() }
    )
  end
  local uiManifest = manifest --[[@as table]]
  local manifestAssets = uiManifest.assets
  if type(manifestAssets) ~= "table" then
    Errors.raise("FIELD_UI_MANIFEST_INVALID", "field UI manifest has no assets", {})
  end
  local frameAsset = manifestAssets["hgss.dialogue_frame.tiles"]
  if type(frameAsset) ~= "table" or type(frameAsset.image) ~= "string" then
    Errors.raise("FIELD_UI_MANIFEST_INVALID", "field UI manifest has no dialogue frame strip", {})
  end

  local self = setmetatable({
    _cacheFs = cacheFs,
    _theme = theme,
    _graphics = graphics,
    fontId = fontId,
    fontDef = def,
    atlas = nil,
    _quads = nil,
    _manifest = manifest,
    _frameImage = nil,
    _frameQuadCache = nil,
  }, FieldDialogueRenderer)

  local data = cacheFs:read(FieldFontCache.atlasPath(fontId))
  if not data then
    Errors.raise(
      FieldErrors.FONT_ATLAS_MISSING,
      "font atlas missing at " .. FieldFontCache.atlasPath(fontId),
      { fontId = fontId, path = FieldFontCache.atlasPath(fontId) }
    )
  end
  self.atlas = graphics.newImage(love.filesystem.newFileData(data, FieldFontCache.atlasPath(fontId)))
  local frameImagePath = frameAsset.image
  local frameData = cacheFs:read(frameImagePath)
  if not frameData then
    self:release()
    Errors.raise(
      "FIELD_UI_FRAME_ATLAS_MISSING",
      "dialogue frame strip missing at " .. frameImagePath,
      { path = frameImagePath }
    )
  end
  local ok, err = pcall(function()
    self.atlas:setFilter("nearest", "nearest")
    self._frameImage = graphics.newImage(love.filesystem.newFileData(frameData, frameImagePath))
    self._frameImage:setFilter("nearest", "nearest")
    self:_buildQuads()
  end)
  if not ok then
    self:release()
    error(err)
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

-- The 18 tile quads of one frame: each 8x8 tile of the strip row named by
-- the manifest rect. Built lazily per frame index and cached, so a session
-- that only ever shows one frame never materializes the other rows.
---@param frameIndex integer
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad[]
function FieldDialogueRenderer:_buildFrameQuads(frameIndex, rect)
  local lg = assert(self._graphics)
  local image = assert(self._frameImage)
  local atlasWidth, atlasHeight = image:getWidth(), image:getHeight()
  local cache = self._frameQuadCache or {}
  local quads = cache[frameIndex]
  if quads == nil then
    quads = {}
    for tile = 0, rect.width / 8 - 1 do
      quads[tile] = lg.newQuad(rect.x + tile * 8, rect.y, 8, 8, atlasWidth, atlasHeight)
    end
    cache[frameIndex] = quads
  end
  self._frameQuadCache = cache
  return quads
end

-- Converts marker text to glyph runs through the compiled charmap.
-- Characters without a glyph render the compiled fallback glyph; marker text
-- is developer aid, never silently dropped.

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

-- Draws the player's selected HGSS user-frame: the strip row named by the
-- manifest rect for the status frame index, composed by the audited
-- DrawFrameAndWindow2 tilemap around the content box. The content region
-- itself stays uncovered, so the world shows through the window. A status
-- without a frame index (a host that carries no player options) draws no
-- frame at all rather than inventing one.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueTheme.Layout
function FieldDialogueRenderer:_drawFrame(status, layout)
  local frameIndex = status.frameIndex
  if frameIndex == nil then
    return
  end
  local lg = assert(self._graphics)
  local image = assert(self._frameImage)
  local frames = assert(self._manifest and self._manifest.dialogueFrames)
  local rect = frames.frameTiles[frameIndex]
  assert(rect ~= nil, "dialogue frame index " .. tostring(frameIndex) .. " is outside the generated frame set")
  local quads = self:_buildFrameQuads(frameIndex, rect)
  lg.setColor(1, 1, 1, 1)
  for _, placement in ipairs(self._theme.frameTilePlacements(layout.box)) do
    local tile = assert(quads[placement.tile])
    for row = 0, (placement.spanY or 1) - 1 do
      for col = 0, (placement.spanX or 1) - 1 do
        lg.draw(image, tile, placement.x + col * 8, placement.y + row * 8)
      end
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
    self:_drawFrame(status, layout)
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
  if self._frameImage and self._frameImage.release then
    self._frameImage:release()
  end
  self.atlas, self._frameImage = nil, nil
  self._quads, self._frameQuadCache = nil, nil
end

-- One positioned glyph of marker text: the atlas quad and the advance to the
-- next run.

---@class FieldDialogueRenderer.GlyphRun
---@field quad love.Quad?
---@field advance number

return FieldDialogueRenderer
