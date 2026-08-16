-- Renders the signpost controller snapshot into the viewport's centered 4:3
-- reference frame: the HGSS signpost frame strip drawn by the audited
-- DrawFrameAndWindow3 tilemap (source types 0/1 additionally blit the
-- wayfinding row as a 6x4 grid and the divider tile 8), the shared
-- FieldTextRenderer glyph text, all translated by the logical wipe offset --
-- the whole signpost BG layer slides, and the hidden -48 position sits below
-- the screen. Per type geometry comes from the window style catalogue;
-- the strip and wayfinding rows are the generated field-UI manifest assets,
-- with the wayfinding row selected by the appearance's exact (type, map)
-- pair. Visibility is keyed on status().active, never on logicalYOffset
-- alone, so the wipe-out endpoint-check reset can never flash the cleared
-- window at the reset position. Interpolation between the previous and the
-- current fixed-tick offset uses the session render alpha, clamped into
-- [0, 1], and is a pure function of the controller's paired wipe history:
-- the renderer holds no interpolation state and never calls back into the
-- controller. Resolved style records are the catalogue's stored records
-- (never copies), so each draw resolves fresh without caching. Construction
-- is failure-safe: a missing strip or wayfinding atlas is a typed error, a
-- quad failure after the images were created releases them before
-- rethrowing, and draw() restores every graphics state it touched. The
-- runtime-validated manifest is injected explicitly; this renderer never
-- reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldSignpostTheme = require("libs.engine.src.FieldSignpostTheme")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")
local FieldDrawState = require("libs.engine.src.FieldDrawState")

---@class FieldSignpostRenderer
---@field _graphics love.Graphics
---@field _windowStyles FieldWindowStyles
---@field _text FieldTextRenderer the shared glyph atlas/line drawing collaborator
---@field _manifest table the generated field-UI manifest
---@field _tilesImage love.Image? the signpost frame strip
---@field _wayfindingImage love.Image? the wayfinding atlas
---@field _tileQuads love.Quad[]? the 18 strip tile quads
---@field _wayfindingQuadCache table<string, love.Quad[]>|nil per-(type,map) row quads, built lazily
local FieldSignpostRenderer = {}
FieldSignpostRenderer.__index = FieldSignpostRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class; opts.manifest: the already-validated generated field-UI manifest
-- the runtime loaded once (FieldRuntime.uiManifest); opts.text: the shared
-- FieldTextRenderer (FieldState owns exactly one); opts.graphics: injectable
-- LÖVE graphics namespace so tests can record draw calls (LÖVE itself
-- remains an allowed presentation-layer dependency: the PNG bytes still
-- enter through love.filesystem.newFileData); opts.windowStyles: the
-- per-runtime window style catalogue the controller's styleId resolves in.

---@param opts { cacheFs: CacheFs, manifest: table, text: FieldTextRenderer, windowStyles: FieldWindowStyles, graphics?: love.Graphics? }
---@return FieldSignpostRenderer
function FieldSignpostRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldSignpostRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldSignpostRenderer requires love.graphics")
  local windowStyles = opts.windowStyles
  assert(
    windowStyles and type(windowStyles.resolve) == "function",
    "FieldSignpostRenderer requires a window style catalogue"
  )
  local text = opts.text
  assert(text and type(text.drawLine) == "function", "FieldSignpostRenderer requires the shared FieldTextRenderer")
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "FieldSignpostRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the signpost strip, the wayfinding atlas, and the strip's tile
  -- rect. The runtime boot already validated the full manifest; the renderer
  -- resolves what it draws.
  local tilesAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_TILES],
    "the field-UI manifest must carry the signpost tiles asset"
  )
  local wayfindingAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING],
    "the field-UI manifest must carry the signpost wayfinding asset"
  )
  local tilesPath = assert(tilesAsset.image, "the signpost tiles asset must name an image path")
  local wayfindingPath = assert(wayfindingAsset.image, "the wayfinding asset must name an image path")
  assert(
    type(manifest.signposts) == "table"
      and type(manifest.signposts.frame) == "table"
      and type(manifest.signposts.frame.tiles) == "table",
    "the field-UI manifest must carry the signpost frame section"
  )

  local self = setmetatable({
    _graphics = graphics,
    _windowStyles = windowStyles,
    _text = text,
    _manifest = manifest,
    _tilesImage = nil,
    _wayfindingImage = nil,
    _tileQuads = nil,
    _wayfindingQuadCache = nil,
  }, FieldSignpostRenderer)

  local tilesData = cacheFs:read(tilesPath)
  if not tilesData then
    self:release()
    Errors.raise(FieldErrors.FIELD_UI_SIGNPOST_TILES_MISSING, "signpost frame strip missing at " .. tilesPath, {
      path = tilesPath,
    })
  end
  local wayfindingData = cacheFs:read(wayfindingPath)
  if not wayfindingData then
    self:release()
    Errors.raise(FieldErrors.FIELD_UI_WAYFINDING_MISSING, "wayfinding atlas missing at " .. wayfindingPath, {
      path = wayfindingPath,
    })
  end
  local ok, err = pcall(function()
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
  local tiles = assert(self._tilesImage)
  local rect = assert(self._manifest.signposts.frame.tiles)
  local tileQuads = {}
  for tile = 0, rect.width / 8 - 1 do
    tileQuads[tile] = lg.newQuad(rect.x + tile * 8, rect.y, 8, 8, tiles:getWidth(), tiles:getHeight())
  end
  self._tileQuads = tileQuads
end

-- The 24 tile quads of one wayfinding row (the manifest rect for the exact
-- (type, map) pair). Built lazily per pair and cached, so a session that
-- only ever shows full-width signs never materializes the rows.
---@param key string the "type.map" pair
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad[]
function FieldSignpostRenderer:_wayfindingQuads(key, rect)
  local cache = self._wayfindingQuadCache or {}
  local quads = cache[key]
  if quads == nil then
    local lg = assert(self._graphics)
    local image = assert(self._wayfindingImage)
    quads = {}
    for tile = 0, rect.width / 8 - 1 do
      quads[tile] = lg.newQuad(rect.x + tile * 8, rect.y, 8, 8, image:getWidth(), image:getHeight())
    end
    cache[key] = quads
  end
  self._wayfindingQuadCache = cache
  return quads
end

-- The wipe translation for this render: the current fixed-tick offset,
-- interpolated from the previous fixed-tick offset by the session render
-- alpha (clamped into [0, 1]). Pure: only the status pair is read, the
-- renderer holds no interpolation state, and the controller is never called
-- back, so repeated draws under the same status hit the same positions.
---@param status FieldSignpostController.Status
---@param alpha number?
---@return number
function FieldSignpostRenderer:_wipeY(status, alpha)
  local a = math.min(math.max(alpha or 1, 0), 1)
  local previous = status.previousLogicalYOffset
  local current = status.logicalYOffset
  return FieldSignpostTheme.wipeY(previous + (current - previous) * a)
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
    local types =
      assert(self._manifest.signposts and self._manifest.signposts.types, "the manifest must carry signpost types")
    -- The exact (type, map) pair selects the row; a type requiring graphic
    -- art without a manifest row for its pair is a manifest/source-contract
    -- failure, never a fallback to another map's row.
    local manifestRect = types[appearance.type]
      and types[appearance.type].wayfinding
      and types[appearance.type].wayfinding[appearance.map]
    assert(
      manifestRect ~= nil,
      "the generated manifest must index the wayfinding row for signpost (type, map) "
        .. tostring(appearance.type)
        .. ","
        .. tostring(appearance.map)
    )
    local wayfinding = assert(self._wayfindingImage)
    local key = appearance.type .. ":" .. appearance.map
    local quads = self:_wayfindingQuads(key, manifestRect)
    for _, placement in ipairs(FieldSignpostTheme.wayfindingPlacements(graphicRegion)) do
      lg.draw(wayfinding, assert(quads[placement.tile]), placement.x, placement.y + wipe)
    end
  end
end

-- Draws the signpost into viewport.referenceFrame. No-op (and no state
-- touched) when the controller is inactive or this renderer is disposed.
-- Restores canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally.

---@param controller FieldSignpostController
---@param viewport { referenceFrame: FieldDialogueTheme.Rect }
---@param alpha number? session render interpolation factor, clamped into [0, 1]
function FieldSignpostRenderer:draw(controller, viewport, alpha)
  if not controller or not self._tilesImage then
    return
  end
  local status = controller:status()
  -- The window is presented only while the controller owns it: keying on
  -- status().active (never logicalYOffset alone) is what keeps the wipe-out
  -- endpoint-check reset from flashing the cleared window at position 0.
  -- An inactive draw touches no renderer state.
  if not status.active then
    return
  end
  local lg = assert(self._graphics)
  FieldDrawState.protectedDraw(lg, function()
    -- Everything draws in reference-canvas coordinates under one
    -- translate(origin) + scale transform; the per-type geometry from the
    -- style catalogue is already reference-space, so nothing is scaled twice.
    local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    local wipe = self:_wipeY(status, alpha)
    -- resolve() returns the catalogue's stored record (never a copy), so the
    -- style is resolved fresh on every draw without caching.
    local style =
      assert(self._windowStyles:resolve(status.styleId), "unknown window style " .. tostring(status.styleId))
    local appearance = status.sourceAppearance
    local typeRecord = appearance and style.types and style.types[appearance.type]
    local contentGeometry = (typeRecord and typeRecord.contentGeometry) or style.contentGeometry
    assert(contentGeometry ~= nil, "window style " .. tostring(status.styleId) .. " carries no content geometry")
    self:_drawFrame(status, typeRecord and typeRecord.graphicRegion, wipe)
    local lineY = contentGeometry.y + wipe
    for _, tokens in ipairs(status.visibleLines) do
      self._text:drawLine(tokens, contentGeometry.x, lineY)
      lineY = lineY + FieldSignpostTheme.LINE_HEIGHT
    end
  end)
end

function FieldSignpostRenderer:release()
  if self._tilesImage and self._tilesImage.release then
    self._tilesImage:release()
  end
  if self._wayfindingImage and self._wayfindingImage.release then
    self._wayfindingImage:release()
  end
  self._tilesImage, self._wayfindingImage = nil, nil
  self._tileQuads, self._wayfindingQuadCache = nil, nil
end

return FieldSignpostRenderer
