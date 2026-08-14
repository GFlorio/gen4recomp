-- Renders the signpost controller snapshot into the viewport's centered 4:3
-- reference frame: the HGSS signpost frame strip drawn by the audited
-- DrawFrameAndWindow3 tilemap (source types 0/1 additionally blit the
-- wayfinding row as a 6x4 grid and the divider tile 8), the extracted glyph
-- atlas text, all translated by the logical wipe offset -- the whole signpost
-- BG layer slides, and the hidden -48 position sits below the screen. Per
-- type geometry comes from the sealed window style registry; the strip and
-- wayfinding rows are the generated field-UI manifest assets. Visibility is
-- keyed on status().active, never on logicalYOffset alone, so the wipe-out
-- endpoint-check reset can never flash the cleared window at the reset
-- position. Interpolation between the previous and the current fixed-tick
-- offset uses the session render alpha, clamped into [0, 1], and never calls
-- back into the controller. Construction is failure-safe: a missing
-- manifest, strip, or wayfinding atlas is a typed error, a quad failure
-- after the images were created releases them before rethrowing, and draw()
-- restores every graphics state it touched.

local Errors = require("libs.errors.src.Errors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldSignpostTheme = require("libs.engine.src.FieldSignpostTheme")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

---@class FieldSignpostRenderer
---@field _cacheFs CacheFs
---@field _graphics love.Graphics
---@field _windowStyles FieldWindowStyleRegistry
---@field fontId integer
---@field fontDef FieldFontDef
---@field atlas love.Image?
---@field _quads table<integer, love.Quad>?
---@field _manifest table|nil the generated field-UI manifest
---@field _tilesImage love.Image? the signpost frame strip
---@field _wayfindingImage love.Image? the wayfinding atlas
---@field _tileQuads love.Quad[]? the 18 strip tile quads
---@field _wayfindingQuadCache table<integer, love.Quad[]>|nil per-type row quads, built lazily
---@field _lastOffset number? previous fixed-tick wipe offset (interpolation)
---@field _activeLast boolean the last draw saw an active window (interpolation snaps across inactive gaps)
local FieldSignpostRenderer = {}
FieldSignpostRenderer.__index = FieldSignpostRenderer

-- opts.cacheFs: version-scoped private cache holding the compiled font def,
-- the font atlas PNG, and the generated field-UI class; opts.graphics:
-- injectable LÖVE graphics namespace; opts.windowStyles: the sealed
-- per-runtime window style registry the controller's styleId resolves in.

---@param opts { cacheFs: CacheFs, windowStyles: FieldWindowStyleRegistry, fontId?: integer, graphics?: love.Graphics? }
---@return FieldSignpostRenderer
function FieldSignpostRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.loadLua,
    "FieldSignpostRenderer requires a CacheFs-shaped object"
  )
  local fontId = opts.fontId or 0
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldSignpostRenderer requires love.graphics")
  local windowStyles = opts.windowStyles
  assert(
    windowStyles and type(windowStyles.resolve) == "function",
    "FieldSignpostRenderer requires a window style registry"
  )
  local cacheFs = opts.cacheFs

  local def = FieldFontLoader.load(cacheFs, fontId)

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the signpost strip, the wayfinding atlas, and the strip's tile
  -- rect. The runtime boot already validates the full manifest; the renderer
  -- resolves what it draws.
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
  local tilesAsset = manifestAssets["hgss.signpost.tiles"]
  local wayfindingAsset = manifestAssets["hgss.signpost.wayfinding"]
  local frameTiles = uiManifest.signposts and uiManifest.signposts.frame and uiManifest.signposts.frame.tiles
  if
    type(tilesAsset) ~= "table"
    or type(tilesAsset.image) ~= "string"
    or type(wayfindingAsset) ~= "table"
    or type(wayfindingAsset.image) ~= "string"
    or type(frameTiles) ~= "table"
    or type(frameTiles.width) ~= "number"
  then
    Errors.raise("FIELD_UI_MANIFEST_INVALID", "field UI manifest has no signpost frame/wayfinding assets", {})
  end

  local self = setmetatable({
    _cacheFs = cacheFs,
    _graphics = graphics,
    _windowStyles = windowStyles,
    fontId = fontId,
    fontDef = def,
    atlas = nil,
    _quads = nil,
    _manifest = manifest,
    _tilesImage = nil,
    _wayfindingImage = nil,
    _tileQuads = nil,
    _wayfindingQuadCache = nil,
    _lastOffset = nil,
    _activeLast = false,
  }, FieldSignpostRenderer)

  local data = cacheFs:read(FieldFontCache.atlasPath(fontId))
  if not data then
    Errors.raise(
      "FONT_ATLAS_MISSING",
      "font atlas missing at " .. FieldFontCache.atlasPath(fontId),
      { fontId = fontId, path = FieldFontCache.atlasPath(fontId) }
    )
  end
  self.atlas = graphics.newImage(love.filesystem.newFileData(data, FieldFontCache.atlasPath(fontId)))
  local tilesPath = tilesAsset.image
  local tilesData = cacheFs:read(tilesPath)
  if not tilesData then
    self:release()
    Errors.raise("FIELD_UI_SIGNPOST_TILES_MISSING", "signpost frame strip missing at " .. tilesPath, {
      path = tilesPath,
    })
  end
  local wayfindingPath = wayfindingAsset.image
  local wayfindingData = cacheFs:read(wayfindingPath)
  if not wayfindingData then
    self:release()
    Errors.raise("FIELD_UI_WAYFINDING_MISSING", "wayfinding atlas missing at " .. wayfindingPath, {
      path = wayfindingPath,
    })
  end
  local ok, err = pcall(function()
    self.atlas:setFilter("nearest", "nearest")
    self._tilesImage = graphics.newImage(love.filesystem.newFileData(tilesData, tilesPath))
    self._tilesImage:setFilter("nearest", "nearest")
    self._wayfindingImage = graphics.newImage(love.filesystem.newFileData(wayfindingData, wayfindingPath))
    self._wayfindingImage:setFilter("nearest", "nearest")
    self:_buildQuads()
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

function FieldSignpostRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local atlas = assert(self.atlas)
  local width, height = atlas:getWidth(), atlas:getHeight()
  local quads = {}
  for code, glyph in pairs(self.fontDef.glyphs) do
    quads[code] = lg.newQuad(glyph.x, glyph.y, glyph.w, glyph.h, width, height)
  end
  self._quads = quads
  local tiles = assert(self._tilesImage)
  local rect = assert(self._manifest.signposts.frame.tiles)
  local tileQuads = {}
  for tile = 0, rect.width / 8 - 1 do
    tileQuads[tile] = lg.newQuad(rect.x + tile * 8, rect.y, 8, 8, tiles:getWidth(), tiles:getHeight())
  end
  self._tileQuads = tileQuads
end

-- The 24 tile quads of one wayfinding row (the manifest rect for the source
-- type). Built lazily per type and cached, so a session that only ever shows
-- full-width signs never materializes the rows.
---@param sourceType integer
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad[]
function FieldSignpostRenderer:_wayfindingQuads(sourceType, rect)
  local cache = self._wayfindingQuadCache or {}
  local quads = cache[sourceType]
  if quads == nil then
    local lg = assert(self._graphics)
    local image = assert(self._wayfindingImage)
    quads = {}
    for tile = 0, rect.width / 8 - 1 do
      quads[tile] = lg.newQuad(rect.x + tile * 8, rect.y, 8, 8, image:getWidth(), image:getHeight())
    end
    cache[sourceType] = quads
  end
  self._wayfindingQuadCache = cache
  return quads
end

-- Converts marker text to glyph runs through the compiled charmap.
-- Characters without a glyph render the compiled fallback glyph; marker text
-- is developer aid, never silently dropped.

---@param text string
---@return FieldSignpostRenderer.GlyphRun[]
function FieldSignpostRenderer:_glyphRuns(text)
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
-- marker color, keeping its measured layout width.

---@param tokens MessageToken[]
---@param x number
---@param y number
---@param advanceX number[]
function FieldSignpostRenderer:_drawMarkerTokens(tokens, x, y, advanceX)
  local lg = assert(self._graphics)
  local atlas = assert(self.atlas)
  local color = FieldSignpostTheme.colors.marker
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

-- Draws one window line at the reference-canvas position: glyphs through the
-- atlas (identity tint: the compiled ink/shadow/background colors are baked),
-- non-glyph tokens as compact markers.

---@param tokens MessageToken[]
---@param x number
---@param y number
function FieldSignpostRenderer:_drawLine(tokens, x, y)
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
function FieldSignpostRenderer:_flushMarkers(markers, advanceX, y)
  if #markers == 0 then
    return
  end
  self:_drawMarkerTokens(markers, advanceX[1], y, advanceX)
  for i = 1, #markers do
    markers[i] = nil
  end
end

-- The wipe translation for this render: the current fixed-tick offset,
-- interpolated from the previous fixed-tick offset by the session render
-- alpha (clamped into [0, 1]) when the window has been active continuously.
-- An inactive gap snaps, so a fresh show never slides in from a stale
-- offset. Only reads the snapshot; the controller is never called back.
---@param status FieldSignpostController.Status
---@param alpha number?
---@return number
function FieldSignpostRenderer:_wipeY(status, alpha)
  local current = status.logicalYOffset
  local drawn = current
  if alpha ~= nil and self._activeLast then
    assert(self._lastOffset ~= nil, "interpolation requires the previous fixed-tick offset")
    drawn = self._lastOffset + (current - self._lastOffset) * math.min(math.max(alpha, 0), 1)
  end
  self._activeLast = true
  self._lastOffset = current
  return FieldSignpostTheme.wipeY(drawn)
end

-- Draws the signpost frame strip by the audited tilemap, and for source
-- types with a graphic region the wayfinding row (24 tiles as a 6x4 grid)
-- plus the divider tile. The whole surface is translated by the wipe.

---@param status FieldSignpostController.Status
---@param graphicRegion FieldDialogueTheme.Rect? the type's wayfinding region
---@param wipe number
function FieldSignpostRenderer:_drawFrame(status, graphicRegion, wipe)
  local lg = assert(self._graphics)
  local image = assert(self._tilesImage)
  local tileQuads = assert(self._tileQuads)
  lg.setColor(1, 1, 1, 1)
  local kind = graphicRegion and "graphic" or "full"
  for _, placement in ipairs(FieldSignpostTheme.frameTilePlacements(kind)) do
    local tile = assert(tileQuads[placement.tile])
    for row = 0, (placement.spanY or 1) - 1 do
      for col = 0, (placement.spanX or 1) - 1 do
        lg.draw(image, tile, placement.x + col * 8, placement.y + row * 8 + wipe)
      end
    end
  end
  if graphicRegion then
    local appearance = assert(status.sourceAppearance)
    local types = assert(self._manifest and self._manifest.signposts and self._manifest.signposts.types)
    local manifestRect = types[appearance.type] and types[appearance.type].wayfinding
    assert(
      manifestRect ~= nil,
      "the generated manifest must index the wayfinding row for signpost type " .. tostring(appearance.type)
    )
    assert(
      manifestRect.width == FieldSignpostTheme.WAYFINDING_TILES * 8 and manifestRect.height == 8,
      "the wayfinding row must be the 24-tile grid source"
    )
    local wayfinding = assert(self._wayfindingImage)
    local quads = self:_wayfindingQuads(appearance.type, manifestRect)
    for _, placement in ipairs(FieldSignpostTheme.wayfindingPlacements(graphicRegion)) do
      lg.draw(wayfinding, assert(quads[placement.tile]), placement.x, placement.y + wipe)
    end
  end
end

-- Draws the signpost into viewport.referenceFrame. No-op (and no state
-- touched) when the controller is inactive or this renderer has no atlas.
-- Restores canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally.

---@param controller FieldSignpostController
---@param viewport { referenceFrame: FieldDialogueTheme.Rect }
---@param alpha number? session render interpolation factor, clamped into [0, 1]
function FieldSignpostRenderer:draw(controller, viewport, alpha)
  if not controller or not self.atlas then
    return
  end
  local status = controller:status()
  -- The window is presented only while the controller owns it: keying on
  -- status().active (never logicalYOffset alone) is what keeps the wipe-out
  -- endpoint-check reset from flashing the cleared window at position 0.
  if not status.active then
    self._activeLast = false
    return
  end
  local lg = assert(self._graphics)

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
    -- translate(origin) + scale transform; the per-type geometry from the
    -- style registry is already reference-space, so nothing is scaled twice.
    local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
    lg.push()
    pushed = true
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    local wipe = self:_wipeY(status, alpha)
    local style =
      assert(self._windowStyles:resolve(status.styleId), "unknown window style " .. tostring(status.styleId))
    local appearance = status.sourceAppearance
    local typeRecord = appearance and style.types and style.types[appearance.type]
    local contentGeometry = (typeRecord and typeRecord.contentGeometry) or style.contentGeometry
    assert(contentGeometry ~= nil, "window style " .. tostring(status.styleId) .. " carries no content geometry")
    self:_drawFrame(status, typeRecord and typeRecord.graphicRegion, wipe)
    local lineY = contentGeometry.y + wipe
    for _, tokens in ipairs(status.visibleLines) do
      self:_drawLine(tokens, contentGeometry.x, lineY)
      lineY = lineY + FieldSignpostTheme.LINE_HEIGHT
    end
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

function FieldSignpostRenderer:release()
  if self.atlas and self.atlas.release then
    self.atlas:release()
  end
  if self._tilesImage and self._tilesImage.release then
    self._tilesImage:release()
  end
  if self._wayfindingImage and self._wayfindingImage.release then
    self._wayfindingImage:release()
  end
  self.atlas, self._tilesImage, self._wayfindingImage = nil, nil, nil
  self._quads, self._tileQuads, self._wayfindingQuadCache = nil, nil, nil
  self._lastOffset, self._activeLast = nil, false
end

-- One positioned glyph of marker text: the atlas quad and the advance to the
-- next run.

---@class FieldSignpostRenderer.GlyphRun
---@field quad love.Quad?
---@field advance number

return FieldSignpostRenderer
