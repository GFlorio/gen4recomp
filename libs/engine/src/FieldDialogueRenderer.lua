-- Renders the modal dialogue box into the viewport's centered 4:3 reference
-- frame: the authentic HGSS user-frame strip (the player's selected frame
-- index resolved from the generated field-UI manifest and drawn by the
-- DrawFrameAndWindow2 tilemap), the extracted glyph atlas text (ink and
-- shadow baked at import time), and a blinking continue cursor. It owns the
-- frame strip image and builds frame quads lazily per frame index; the
-- shared FieldTextRenderer (owned by FieldState) draws the glyph text. It
-- draws after the 3D world pass and restores every graphics state it
-- touches (canvas, shader, scissor, blend, depth, color). Presentation-only
-- by design: FieldFontLoader owns runtime font definitions and the generated
-- manifest owns frame rects. Construction is failure-safe: a missing frame
-- strip is a typed error, a quad failure after the images were created
-- releases the acquired images before rethrowing, and draw() balances its
-- transform push even when drawing raises. The runtime-validated manifest is
-- injected explicitly; this renderer never reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")
local FieldDrawState = require("libs.engine.src.FieldDrawState")

---@class FieldDialogueRenderer
---@field _theme FieldDialogueTheme
---@field _graphics love.Graphics
---@field _text FieldTextRenderer the shared glyph atlas/line drawing collaborator
---@field _manifest table the generated field-UI manifest
---@field _frameImage love.Image?
---@field _frameQuadCache table<integer, love.Quad[]>|nil per-frame tile quads, built lazily
local FieldDialogueRenderer = {}
FieldDialogueRenderer.__index = FieldDialogueRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (frame strip PNGs); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared FieldTextRenderer (FieldState owns exactly one);
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData); opts.theme:
-- geometry record.

---@param opts { cacheFs: CacheFs, manifest: table, text: FieldTextRenderer, theme?: FieldDialogueTheme, graphics?: love.Graphics? }
---@return FieldDialogueRenderer
function FieldDialogueRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldDialogueRenderer requires a CacheFs-shaped object"
  )
  local theme = opts.theme or FieldDialogueTheme
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldDialogueRenderer requires love.graphics")
  local text = opts.text
  assert(
    text and type(text.drawLine) == "function" and type(text.drawFocusIndicator) == "function",
    "FieldDialogueRenderer requires the shared FieldTextRenderer"
  )
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "FieldDialogueRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the frame strip and every frame's tile rects. The runtime boot
  -- already validated the full manifest, so the renderer only resolves what
  -- it draws.
  local frameAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES],
    "the field-UI manifest must carry the dialogue frame strip asset"
  )
  local frameImagePath = assert(frameAsset.image, "the dialogue frame strip asset must name an image path")

  local self = setmetatable({
    _theme = theme,
    _graphics = graphics,
    _text = text,
    _manifest = manifest,
    _frameImage = nil,
    _frameQuadCache = nil,
  }, FieldDialogueRenderer)

  local frameData = cacheFs:read(frameImagePath)
  if not frameData then
    self:release()
    Errors.raise(
      FieldErrors.FIELD_UI_FRAME_ATLAS_MISSING,
      "dialogue frame strip missing at " .. frameImagePath,
      { path = frameImagePath }
    )
  end
  local ok, err = pcall(function()
    self._frameImage = graphics.newImage(love.filesystem.newFileData(frameData, frameImagePath))
    self._frameImage:setFilter("nearest", "nearest")
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
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
  local frames = assert(self._manifest.dialogueFrames)
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

-- Draws the source screen-focus indicator (the YESNO printer control
-- graphic) once, when the reveal has reached a focus_indicator token: the
-- last visible control in source order wins. Placement is window-relative,
-- not a text-cursor advance: the right edge of the content window, without
-- subtracting the text inset. The indicator and the continuation cursor are
-- distinct source concepts and never suppress each other.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueTheme.Layout
function FieldDialogueRenderer:_drawFocusIndicator(status, layout)
  local lines = status.scrollLines or status.visibleLines
  local tokensByLine = {}
  for _, line in ipairs(lines) do
    tokensByLine[#tokensByLine + 1] = line.tokens or line
  end
  local field = FieldTextRenderer.lastVisibleFocusField(tokensByLine)
  if field ~= nil then
    self._text:drawFocusIndicator(
      field,
      layout.box.x + layout.box.width - FieldFontCache.FOCUS_FRAME_WIDTH,
      layout.box.y
    )
  end
end

-- Draws the dialogue into viewport.referenceFrame at the field logical pixel
-- scale (viewport:logicalPixelScale(camera.zoom)). No-op (and no state
-- touched) when the controller is closed or this renderer is disposed.
-- Restores canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally. The fieldScale is
-- presentation state, not controller state; it bottom-centers the 256x192
-- surface and matches the world logical pixel scale.

---@param controller FieldDialogueController
---@param viewport { referenceFrame: FieldDialogueTheme.Rect }
---@param fieldScale number field logical pixel scale (viewport:logicalPixelScale(camera.zoom))
function FieldDialogueRenderer:draw(controller, viewport, fieldScale)
  -- Inactive (closed) is a pure no-op and checks no scale precondition; an
  -- inactive draw must not touch graphics state or require presentation
  -- parameters. The scale is only required for the active path.
  if not controller or not controller:isModal() or not self._frameImage then
    return
  end
  assert(
    type(fieldScale) == "number"
      and fieldScale > 0
      and fieldScale == fieldScale
      and fieldScale ~= math.huge
      and fieldScale ~= -math.huge,
    "FieldDialogueRenderer:draw requires a finite positive field scale"
  )
  local lg = assert(self._graphics)
  local status = controller:status()
  FieldDrawState.protectedDraw(lg, function()
    -- Everything draws in reference-canvas coordinates under one
    -- translate(origin) + scale transform; the theme never returns
    -- screen-mapped rects, so nothing is scaled twice.
    local layout = self._theme.layout(viewport.referenceFrame, fieldScale)
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    local background = self._text:windowBackgroundColor()
    lg.setColor(background[1], background[2], background[3], background[4])
    lg.rectangle("fill", layout.box.x, layout.box.y, layout.box.width, layout.box.height)
    self:_drawFrame(status, layout)
    local lines = status.scrollLines or status.visibleLines
    local scrollOffset = status.scrollLines and status.scrollOffsetY or 0
    local lineY = layout.text.y - scrollOffset
    for _, line in ipairs(lines) do
      local tokens = line.tokens or line
      self._text:drawLine(tokens, layout.text.x, lineY)
      lineY = lineY + status.lineHeight + status.lineSpacing
    end
    self:_drawFocusIndicator(status, layout)
    self:_drawCursor(status, layout)
  end)
end

function FieldDialogueRenderer:release()
  if self._frameImage and self._frameImage.release then
    self._frameImage:release()
  end
  self._frameImage = nil
  self._frameQuadCache = nil
end

return FieldDialogueRenderer
