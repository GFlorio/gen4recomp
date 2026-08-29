-- Interactive presentation over the non-rendering field runtime.

local WindowConfig = require("game.src.WindowConfig")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldActorAssetProvider = require("libs.engine.src.FieldActorAssetProvider")
local FieldActorDraw = require("libs.engine.src.FieldActorDraw")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local DialoguePresentationLayout = require("libs.engine.src.DialoguePresentationLayout")
local FieldMenuRenderer = require("libs.engine.src.FieldMenuRenderer")
local FieldSignpostRenderer = require("libs.engine.src.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")
local FieldEntranceIndicatorRenderer = require("libs.engine.src.FieldEntranceIndicatorRenderer")
local FieldActorEmoteRenderer = require("libs.engine.src.FieldActorEmoteRenderer")
local FieldTerrainEffectRenderer = require("libs.engine.src.FieldTerrainEffectRenderer")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")
local MapRenderer = require("libs.engine.src.MapRenderer")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
local StartMenuRenderer = require("libs.engine.src.StartMenuRenderer")
local TrainerCardRenderer = require("libs.engine.src.TrainerCardRenderer")

local KEY_DIRECTIONS =
  { w = "north", up = "north", s = "south", down = "south", a = "west", left = "west", d = "east", right = "east" }
local GAMEPAD_DIRECTIONS = { dpup = "north", dpdown = "south", dpleft = "west", dpright = "east" }

---@class FieldStateOptions
---@field zoomConfig table? runtime zoom configuration (runtime contract)
---@field development boolean? product mode (the default) hides the playtest HUD
---@field topologyProvider (fun(width: number, height: number): ScreenTopology)?
---@field saveStore table? global GameSaveStore
---@field saveValidation GameSaveValidation? shared version-aware GameSave validator
---@field audioOutput table? audio-output host namespace for deterministic runtime audio

---@class FieldState
---@field runtime FieldRuntime?
---@field renderer any
---@field dialogueRenderer any
---@field menuRenderer FieldMenuRenderer?
---@field signpostRenderer FieldSignpostRenderer?
---@field startMenuRenderer StartMenuRenderer?
---@field trainerCardRenderer TrainerCardRenderer?
---@field textRenderer FieldTextRenderer? the one shared glyph atlas the UI renderers draw through
---@field _lastGeometrySignature string? the structural presentation-geometry signature the last sync consumed
---@field _pollPresentationTopology boolean whether injected topology changes are polled during draw
---@field presentationActorAssets FieldActorAssetProvider?
---@field _presentationSpriteRefs table<integer, boolean>
---@field _lastActorManager any?
---@field _lastActorVisualRevision integer?
---@field _lastPlayerSpriteId integer?
---@field _actorRecords table[]
---@field _actorDrawStorage FieldActorDrawStorage
---@field _actorAssetLookup fun(spriteId: integer): table
---@field worldParts table[][] ordered map, static building, animated building, neighbor, entrance-indicator, actor, movement-emote, and terrain-effect draw arrays
---@field worldActorItems table[] persistent actor items kept in the world raster
---@field spriteItems table[] persistent presentation-resolution actor sprites
---@field development boolean product mode (default) hides the playtest HUD and ignores the F1/F2 developer binds
---@field topologyProvider fun(width: number, height: number): ScreenTopology
local FieldState = {}
FieldState.__index = FieldState

local NO_DRAWS = {}

local function defaultScreenTopology(width, height)
  local os = love.system and love.system.getOS and love.system.getOS() or ""
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = os == "Android" or os == "iOS",
    role = "world",
  })
end

---@param game table finalized unpublished game or validated loaded GameSave
---@param options FieldStateOptions?
---@return FieldState
function FieldState.new(game, options)
  options = options or {}
  -- Only the documented runtime contract crosses the boundary: the finalized
  -- or loaded game is the runtime's save authority, while state-only options
  -- such as topologyProvider must never become runtime options.
  local runtimeOptions = {
    zoomConfig = options.zoomConfig,
    presentation = true,
    saveStore = options.saveStore,
    saveValidation = options.saveValidation,
    audioOutput = options.audioOutput,
  }
  -- Construction is binary: FieldRuntime.new either raised (boot failed) or
  -- returned a fully usable runtime, so presentation resources are acquired
  -- unconditionally. A failure here releases the booted runtime exactly once
  -- through the shared disposal and rethrows.
  local runtime = FieldRuntime.new(game, runtimeOptions)
  local self = setmetatable({
    runtime = runtime,
    development = options.development == true,
    topologyProvider = options.topologyProvider or defaultScreenTopology,
    _pollPresentationTopology = options.topologyProvider ~= nil,
    _presentationSpriteRefs = {},
    _lastActorManager = nil,
    _lastActorVisualRevision = nil,
    _lastPlayerSpriteId = nil,
    _actorRecords = {},
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
  }, FieldState)
  local ok, err = pcall(function()
    self.renderer = MapRenderer.new({
      clearColor = WindowConfig.BACKGROUND_COLOR,
      worldRasterScale = WindowConfig.WORLD_3D_RASTER_SCALE,
      translucencyMode = MapRenderer.TRANSLUCENCY_APPROXIMATE,
    })
    -- The one shared field-font atlas: dialogue, signpost, and Trainer Card
    -- text all draw through it; the state owns and releases it exactly once.
    self.textRenderer = FieldTextRenderer.new({ cacheFs = runtime.cacheFs })
    self.dialogueRenderer = FieldDialogueRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = self.textRenderer,
    })
    self.menuRenderer = FieldMenuRenderer.new()
    -- The composition: the signpost renderer resolves its per-type geometry
    -- through the immutable window style catalogue, and the Start Menu and
    -- Trainer Card renderers draw the generated application surfaces. Every
    -- renderer consumes the one manifest the runtime already validated;
    -- none of them reloads it. The state owns and releases their GPU
    -- resources; controllers stay pure.
    self.signpostRenderer = FieldSignpostRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = self.textRenderer,
      windowStyles = runtime.windowStyles,
    })
    self.startMenuRenderer = StartMenuRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
    })
    self.trainerCardRenderer = TrainerCardRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = self.textRenderer,
    })
    self.fieldEntranceIndicatorPool = GpuAssetPool.new(runtime.cacheFs)
    self.fieldEntranceIndicatorRenderer =
      FieldEntranceIndicatorRenderer.new(runtime.fieldEntranceIndicatorAsset.model, self.fieldEntranceIndicatorPool)
    self.fieldEmotePool = GpuAssetPool.new(runtime.cacheFs)
    self.fieldEmoteRenderer = FieldActorEmoteRenderer.new(runtime.fieldEmoteModels, self.fieldEmotePool)
    if runtime.fieldEffectAssets and runtime.fieldEffectAssets.effects then
      self.fieldTerrainEffectRenderer =
        FieldTerrainEffectRenderer.new(runtime.fieldEffectAssets, self.fieldEntranceIndicatorPool)
      runtime.fieldTerrainEffectController:setModelFactory(function(kind)
        return self.fieldTerrainEffectRenderer:newInstance(kind)
      end)
    else
      self.fieldTerrainEffectRenderer = {
        drawItems = function()
          return {}
        end,
        dispose = function() end,
      }
    end
    local width, height = love.graphics.getDimensions()
    -- The initial presentation-geometry sync: pointer input must work
    -- before the user has resized the window, so the runtime computes and
    -- stores the Start Menu placement as soon as the graphics dimensions are
    -- known.
    self:resize(width, height)
    runtime.menuHost:setPresentationMetrics(function(text)
      return love.graphics.getFont():getWidth(text)
    end)
    self.presentationActorAssets = FieldActorAssetProvider.new(runtime.cacheFs)
    self._actorAssetLookup = function(spriteId)
      local assets = assert(self.presentationActorAssets, "field presentation assets are unavailable")
      return assert(assets:resident(spriteId), "field actor presentation visual is not resident")
    end
    self:_syncPresentationAssets()
  end)
  if not ok then
    self:dispose()
    error(err)
  end
  return self
end

function FieldState:update(dt)
  self.runtime:update(dt)
  self:_syncPresentationAssets()
end

-- Keep one presentation-provider reference per distinct sprite needed by the
-- current actor set and player. Resource construction is change-driven; draw
-- only reads the provider's active residency.
function FieldState:_syncPresentationAssets()
  local runtime = assert(self.runtime, "field runtime is unavailable")
  local assets = assert(self.presentationActorAssets, "field presentation assets are unavailable")
  local actors = assert(runtime.actors, "field actor manager is unavailable")
  local playerVisual = assert(runtime.playerVisual, "field player visual is unavailable")
  local actorRevision = actors:visualRevision()
  local playerSpriteId = assert(playerVisual.spriteId, "field player visual has no spriteId")
  if
    self._lastActorManager == actors
    and self._lastActorVisualRevision == actorRevision
    and self._lastPlayerSpriteId == playerSpriteId
  then
    return
  end

  local needed = {}
  needed[playerSpriteId] = true
  actors:collectSpriteIds(needed)

  local acquired = {}
  local ok, err = pcall(function()
    for spriteId in pairs(needed) do
      if not self._presentationSpriteRefs[spriteId] then
        assets:acquire(spriteId)
        acquired[#acquired + 1] = spriteId
      end
    end
  end)
  if not ok then
    for _, spriteId in ipairs(acquired) do
      assets:release(spriteId)
    end
    error(err, 0)
  end

  local released = {}
  for spriteId in pairs(self._presentationSpriteRefs) do
    if not needed[spriteId] then
      released[#released + 1] = spriteId
    end
  end
  for _, spriteId in ipairs(released) do
    assets:release(spriteId)
    self._presentationSpriteRefs[spriteId] = nil
  end
  for _, spriteId in ipairs(acquired) do
    self._presentationSpriteRefs[spriteId] = true
  end
  self._lastActorVisualRevision = actorRevision
  self._lastActorManager = actors
  self._lastPlayerSpriteId = playerSpriteId
end

-- Every actor the frame draws: the ROM-derived player billboard first, then the
-- object actors the manager considers present. Records stay presentation-neutral;
-- FieldActorDraw turns them into world draw items against the resident visuals.
function FieldState:_actorDraws(alpha)
  local records = self._actorRecords or {}
  self._actorRecords = records
  records[1] = self.runtime.playerVisual:drawRecord(alpha)
  local actorRecords = self.runtime.actors:drawRecords()
  for index, record in ipairs(actorRecords) do
    records[index + 1] = record
  end
  for index = #records, #actorRecords + 2, -1 do
    records[index] = nil
  end
  local storage = assert(self._actorDrawStorage, "field actor draw storage is unavailable")
  local assetLookup = assert(self._actorAssetLookup, "field actor asset lookup is unavailable")
  return FieldActorDraw.itemsInto(records, assetLookup, storage)
end

-- Refresh the persistent ordered scene parts: the session-owned physical
-- window when outdoor cells are active, otherwise the full logical scene,
-- then actors and transient effects. Logical scene geometry is retained for
-- environment and discontinuous maps but is never drawn alongside cells.
function FieldState:_worldParts(alpha)
  local runtimeMap = self.runtime.runtimeMap
  local worldParts = self.worldParts
  if runtimeMap.coverage then
    worldParts[1] = runtimeMap.coverage:worldParts()
    worldParts[2] = NO_DRAWS
    worldParts[3] = NO_DRAWS
    worldParts[4] = NO_DRAWS
  else
    local sceneRuntime = assert(runtimeMap.sceneRuntime, "field scene presentation is unavailable")
    worldParts[1] = sceneRuntime.mapDraws
    worldParts[2] = sceneRuntime.staticBuildingDraws
    worldParts[3] = sceneRuntime.animatedBuildingDraws
    worldParts[4] = runtimeMap.neighborRuntime and runtimeMap.neighborRuntime.draws or NO_DRAWS
  end
  local indicator = assert(self.runtime.fieldEntranceIndicator, "field entrance indicator is unavailable")
  worldParts[5] = self.fieldEntranceIndicatorRenderer:drawItems(indicator:status())
  local actorItems = self:_actorDraws(alpha)
  local worldActorItems = self.worldActorItems
  local spriteItems = self.spriteItems
  for index = #worldActorItems, 1, -1 do
    worldActorItems[index] = nil
  end
  for index = #spriteItems, 1, -1 do
    spriteItems[index] = nil
  end
  for _, item in ipairs(actorItems) do
    if item.billboardProjection == true then
      spriteItems[#spriteItems + 1] = item
    else
      worldActorItems[#worldActorItems + 1] = item
    end
  end
  worldParts[6] = worldActorItems
  -- _actorDraws (above) refreshed self._actorRecords with this frame's
  -- presentation-neutral records, which is the only place activeEmoteKind
  -- survives; FieldActorDraw's rendered items do not carry it.
  worldParts[7] = self.fieldEmoteRenderer:drawItems(self._actorRecords)
  local terrain = self.runtime.fieldTerrainEffectController
  local terrainRenderer = self.fieldTerrainEffectRenderer
  worldParts[8] = terrainRenderer and terrainRenderer:drawItems(terrain:status(), self.runtime.runtimeMap) or NO_DRAWS
  return worldParts
end

-- The structural presentation-geometry signature: the window dimensions plus
-- every surface identity, role, and safe rectangle. A safe-area change with
-- the same window dimensions must recompute the placement, and a change
-- must not be reported while nothing structural moved (so an active Start
-- Menu pointer capture is not cancelled unnecessarily).
---@param width integer
---@param height integer
---@param topology ScreenTopology
---@return string
function FieldState:_geometrySignature(width, height, topology)
  local parts = { tostring(width), tostring(height) }
  for _, surface in ipairs(topology.surfaces) do
    local safe = surface.safeRect or surface.rect
    parts[#parts + 1] = string.format(
      "|%s:%s:%d:%d:%d:%d",
      tostring(surface.id),
      tostring(surface.role),
      safe.x,
      safe.y,
      safe.width,
      safe.height
    )
  end
  return table.concat(parts)
end

function FieldState:_recordGeometrySignature(width, height, topology)
  self._lastGeometrySignature = self:_geometrySignature(width, height, topology)
end

function FieldState:resize(width, height)
  local provider = self.topologyProvider or defaultScreenTopology
  local topology = provider(width, height)
  self.runtime:resizePresentation(width, height, topology)
  if self._pollPresentationTopology then
    self:_recordGeometrySignature(width, height, topology)
  end
end

function FieldState:draw()
  local lg = love.graphics
  if self.runtime.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Field runtime failed:", 24, 24)
    lg.printf(self.runtime.errorText, 24, 48, lg.getWidth() - 48)
    return
  end
  local width, height = lg.getDimensions()
  assert(width and height, "graphics dimensions are required for field presentation")
  local resized = false
  if width ~= self.runtime.viewport.width or height ~= self.runtime.viewport.height then
    self:resize(width, height)
    resized = true
  end
  if self._pollPresentationTopology and not resized then
    local provider = self.topologyProvider or defaultScreenTopology
    local topology = provider(width, height)
    if self:_geometrySignature(width, height, topology) ~= self._lastGeometrySignature then
      -- Injected providers remain polling-enabled so same-size structural
      -- topology changes still reach the runtime geometry owner.
      self.runtime:resizePresentation(width, height, topology)
      self:_recordGeometrySignature(width, height, topology)
    end
  end
  assert(
    type(self.runtime.destinationWorldPresentable) == "function",
    "field runtime destination presentation capability required"
  )
  if not self.runtime:destinationWorldPresentable() then
    self:_drawScriptScreenFadeIfNeeded()
    return
  end
  local alpha = self.runtime.session:renderAlpha()
  self.renderer:draw(
    self.runtime.runtimeMap.sceneRuntime,
    self.runtime.camera,
    self:_worldParts(alpha),
    self.spriteItems,
    self.runtime.viewport,
    alpha
  )
  assert(
    type(self.runtime.acknowledgeDestinationPresentation) == "function",
    "field runtime destination presentation acknowledgement required"
  )
  self.runtime:acknowledgeDestinationPresentation()
  -- The field/application fade: the host-owned application fade covers
  -- the surface being transitioned (the world viewport plus the Start Menu
  -- placement frame), then the unrelated warp fade over the world viewport.
  local hostStatus = self.runtime.applicationHost:status()
  if hostStatus.fadeAlpha > 0 then
    self:_drawApplicationFade(hostStatus.fadeAlpha)
  end
  local transitionStatus
  if type(self.runtime.transition.presentationStatus) == "function" then
    transitionStatus = self.runtime.transition:presentationStatus()
  else
    transitionStatus = {
      overlay = self.runtime.transition.fadeAlpha > 0 and {
        r = 0,
        g = 0,
        b = 0,
        a = self.runtime.transition.fadeAlpha,
      } or nil,
    }
  end
  local transitionOverlay = transitionStatus.overlay
  if transitionOverlay then
    local rectangle = self.runtime.viewport.worldViewport
    lg.setColor(transitionOverlay.r, transitionOverlay.g, transitionOverlay.b, transitionOverlay.a)
    lg.rectangle("fill", rectangle.x, rectangle.y, rectangle.width, rectangle.height)
  end
  -- Dialogue or signpost attached to the world surface, and only while the
  -- application host presents no modal surface: during a full application
  -- neither is drawn underneath it. The session's at-most-one-owner assert
  -- keeps at most one of the two live in a tick. Both field-attached
  -- surfaces share the same field logical pixel scale (the viewport's
  -- logicalPixelScale of the runtime's effective camera zoom), computed once
  -- per frame and bottom-centered in the viewport reference frame.
  if not hostStatus.menu and not hostStatus.application then
    local fieldScale = self.runtime.viewport:logicalPixelScale(self.runtime.camera.zoom)
    local bounds = self.runtime.viewport.worldViewport
    if type(bounds) ~= "table" or type(bounds.width) ~= "number" or type(bounds.height) ~= "number" then
      bounds = self.runtime.viewport.referenceFrame
    end
    if type(bounds) ~= "table" or type(bounds.width) ~= "number" or type(bounds.height) ~= "number" then
      bounds = {
        x = 0,
        y = 0,
        width = assert(self.runtime.viewport.width),
        height = assert(self.runtime.viewport.height),
      }
    end
    bounds = {
      x = bounds.x,
      y = bounds.y,
      width = math.max(bounds.width, 256 * fieldScale),
      height = math.max(bounds.height, 48 * fieldScale),
    }
    local dialogueModal = self.runtime.dialogue:isModal()
    local dialoguePresentation
    if dialogueModal then
      local manifestPlacement = assert(self.runtime.uiManifest).dialogueFrames.continueCursor.placement
      dialoguePresentation = DialoguePresentationLayout.compute(bounds, {
        scale = fieldScale,
        cursorPlacement = manifestPlacement,
      })
      self.dialogueRenderer:draw(self.runtime.dialogue, self.runtime.viewport, fieldScale, dialoguePresentation)
    end
    if self.runtime.signpost:isModal() then
      self.signpostRenderer:draw(self.runtime.signpost, self.runtime.viewport, alpha, fieldScale)
    end
  end
  -- The one active application surface: the Start Menu through the runtime's
  -- placement record (the same record the host maps pointer input through),
  -- or the Trainer Card in the viewport; never both.
  if hostStatus.menu then
    self.startMenuRenderer:draw(hostStatus.menu, assert(self.runtime.startMenuPlacement))
  elseif hostStatus.application then
    self.trainerCardRenderer:draw(hostStatus.application, self.runtime.viewport)
  end
  local presentation = self.runtime.menuHost:presentation()
  if presentation then
    assert(self.menuRenderer, "field menu renderer is unavailable"):draw(presentation)
  end
  if self.development then
    self:_drawHud()
  end
  self:_drawScriptScreenFadeIfNeeded()
end

local function rectUnion(existing, rect)
  if #existing == 0 then
    return { { x = rect.x, y = rect.y, width = rect.width, height = rect.height } }
  end
  -- Start with rect, subtract every existing rect using axis-aligned subtraction.
  local pending = { { x = rect.x, y = rect.y, width = rect.width, height = rect.height } }
  local result = {}
  for _, ex in ipairs(existing) do
    result[#result + 1] = ex
  end
  local nextPending = {}
  for _, piece in ipairs(pending) do
    -- Subtract existing rects one by one
    local pieces = { piece }
    for _, ex in ipairs(existing) do
      local newPieces = {}
      for _, p in ipairs(pieces) do
        local px2, py2 = p.x + p.width, p.y + p.height
        local ex2x, ex2y = ex.x + ex.width, ex.y + ex.height
        local ix1, iy1 = math.max(p.x, ex.x), math.max(p.y, ex.y)
        local ix2, iy2 = math.min(px2, ex2x), math.min(py2, ex2y)
        if ix2 <= ix1 or iy2 <= iy1 then
          newPieces[#newPieces + 1] = p
        else
          if p.x < ix1 then
            newPieces[#newPieces + 1] = { x = p.x, y = p.y, width = ix1 - p.x, height = p.height }
          end
          if px2 > ix2 then
            newPieces[#newPieces + 1] = { x = ix2, y = p.y, width = px2 - ix2, height = p.height }
          end
          if p.y < iy1 then
            newPieces[#newPieces + 1] = { x = ix1, y = p.y, width = ix2 - ix1, height = iy1 - p.y }
          end
          if py2 > iy2 then
            newPieces[#newPieces + 1] = { x = ix1, y = iy2, width = ix2 - ix1, height = py2 - iy2 }
          end
        end
      end
      pieces = newPieces
    end
    for _, p in ipairs(pieces) do
      nextPending[#nextPending + 1] = p
    end
  end
  for _, p in ipairs(nextPending) do
    result[#result + 1] = p
  end
  return result
end

function FieldState:_drawScriptScreenFadeIfNeeded()
  local screenFade = self.runtime.screenFade
  if screenFade == nil then
    return
  end
  local status = screenFade:status()
  if status.overlay == nil then
    return
  end
  local topology = self.runtime.screenTopology
  assert(topology ~= nil and type(topology.surfaces) == "table", "script screen fade requires a current topology")
  local surfaces = topology.surfaces
  local rects = {}
  for _, surface in ipairs(surfaces) do
    rects = rectUnion(rects, surface.rect)
  end
  local lg = love.graphics
  local overlay = status.overlay
  local prevR, prevG, prevB, prevA = lg.getColor()
  lg.setColor(overlay.r, overlay.g, overlay.b, overlay.a)
  for _, rect in ipairs(rects) do
    lg.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  end
  lg.setColor(prevR, prevG, prevB, prevA)
end

-- The application fade coverage: the world viewport plus the Start Menu
-- placement frame as a set of non-overlapping rectangles, so the union of
-- separated surfaces is painted once each and the gap between them never is.
-- The world rect is always painted; the frame contributes only the strips
-- outside its intersection with the world (a fully contained frame adds
-- nothing, so no region is alpha-doubled).
---@param world ScreenTopology.Rectangle
---@param frame ScreenTopology.Rectangle
---@return ScreenTopology.Rectangle[]
local function fadeRects(world, frame)
  local rects = { world }
  local ix = math.max(world.x, frame.x)
  local iy = math.max(world.y, frame.y)
  local ix2 = math.min(world.x + world.width, frame.x + frame.width)
  local iy2 = math.min(world.y + world.height, frame.y + frame.height)
  if ix2 <= ix or iy2 <= iy then
    -- Disjoint surfaces: the frame is painted in full.
    rects[#rects + 1] = frame
    return rects
  end
  if frame.x < ix then
    rects[#rects + 1] = { x = frame.x, y = frame.y, width = ix - frame.x, height = frame.height }
  end
  if frame.x + frame.width > ix2 then
    rects[#rects + 1] = { x = ix2, y = frame.y, width = frame.x + frame.width - ix2, height = frame.height }
  end
  if frame.y < iy then
    rects[#rects + 1] = { x = ix, y = frame.y, width = ix2 - ix, height = iy - frame.y }
  end
  if frame.y + frame.height > iy2 then
    rects[#rects + 1] = { x = ix, y = iy2, width = ix2 - ix, height = frame.y + frame.height - iy2 }
  end
  return rects
end

-- The application fade: the union of the world viewport and the Start Menu
-- placement frame, so on a dual-display topology the auxiliary surface region
-- goes black with the world and no menu surface can stay visible while only
-- the world viewport fades. Disjoint surfaces paint as separate rectangles
-- (the gap between them stays untouched), and overlapping regions are
-- painted once, never twice.
---@param alpha number
function FieldState:_drawApplicationFade(alpha)
  local lg = love.graphics
  local world = self.runtime.viewport.worldViewport
  local frame = assert(self.runtime.startMenuPlacement, "the application fade requires the placement record").frame
  lg.setColor(0, 0, 0, alpha)
  for _, rect in
    ipairs(fadeRects(world, frame --[[@as ScreenTopology.Rectangle]]))
  do
    lg.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  end
end

-- The playtest HUD: map identity, the player's field state, the save status,
-- and the controls. Everything else stays out of the frame until the real
-- game UI replaces even this.
function FieldState:_drawHud()
  local lg = love.graphics
  local lines = {
    string.format("map %d  %s", self.runtime.runtimeMap.mapId, self.runtime.runtimeMap.mapSymbol),
    string.format(
      "player (%d,%d) y %.3f surface %d %s %s",
      self.runtime.player.fieldX,
      self.runtime.player.fieldZ,
      self.runtime.player.worldY,
      self.runtime.player.surfaceId,
      self.runtime.player.facing,
      self.runtime.player.motion
    ),
    self.runtime.saveStatus or "save not written this run",
    "WASD/arrows move   Z/Space/Enter action   X/Backspace cancel   M menu   -/= zoom" .. "   0 reset zoom   Esc quit",
  }
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 12, 12, 900, 20 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for index, line in ipairs(lines) do
    lg.print(line, 20, 12 + (index - 1) * 20)
  end
end

---@param key string
---@param scancode string?
---@param isrepeat boolean?
function FieldState:keypressed(key, scancode, isrepeat)
  if key == "escape" then
    love.event.quit(0)
  end
  if self.runtime.actionKeys[key] then
    self.runtime.input:pressAction("key:" .. key)
  end
  if self.runtime.cancelKeys[key] then
    self.runtime.input:pressCancel("key:" .. key)
  end
  if self.runtime.menuKeys[key] then
    self.runtime.input:pressMenu("key:" .. key)
  end
  if key == "-" or key == "kp-" then
    self.runtime.zoom:zoomOut()
    self.runtime:applyZoomChange()
    return
  end
  if key == "=" or key == "+" or key == "kp+" then
    self.runtime.zoom:zoomIn()
    self.runtime:applyZoomChange()
    return
  end
  if key == "0" or key == "kp0" then
    self.runtime.zoom:reset()
    self.runtime:applyZoomChange()
    return
  end
  local direction = KEY_DIRECTIONS[key]
  if direction then
    self.runtime.input:pressDirection(direction, "key:" .. key)
  end
end

---@param key string
---@param scancode string?
function FieldState:keyreleased(key, scancode)
  -- Release mirrors press: one physical key may drive several held semantic
  -- states (e.g. Action bound to an arrow key), so every matching binding
  -- releases, never just the first.
  if self.runtime.actionKeys[key] then
    self.runtime.input:releaseAction("key:" .. key)
  end
  if self.runtime.cancelKeys[key] then
    self.runtime.input:releaseCancel("key:" .. key)
  end
  if self.runtime.menuKeys[key] then
    self.runtime.input:releaseMenu("key:" .. key)
  end
  local direction = KEY_DIRECTIONS[key]
  if direction then
    self.runtime.input:releaseDirection("key:" .. key)
  end
end

-- Focus loss clears held and edge state so a blurred window cannot feed a
-- stale Action into the next frame's dialogue or movement.
---@param focused boolean
function FieldState:focus(focused)
  if not focused then
    self.runtime.input:clearAll()
  end
end

-- Gamepad Action is the south face button ("a"), Cancel the east face
-- button ("b"), and Menu the west face button ("x"), mapped alongside the
-- keyboard bindings. The physical source identity includes the joystick id
-- so two pads cannot alias one button.
---@param joystick love.Joystick
---@param button string
function FieldState:gamepadpressed(joystick, button)
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.runtime.input:pressAction(source)
  end
  if button == "b" then
    self.runtime.input:pressCancel(source)
  end
  if button == "x" then
    self.runtime.input:pressMenu(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.runtime.input:pressDirection(direction, source)
  end
end

---@param joystick love.Joystick
---@param button string
function FieldState:gamepadreleased(joystick, button)
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.runtime.input:releaseAction(source)
  end
  if button == "b" then
    self.runtime.input:releaseCancel(source)
  end
  if button == "x" then
    self.runtime.input:releaseMenu(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.runtime.input:releaseDirection(source)
  end
end

-- FieldInput owns the paired-axis cache and hysteresis so all physical
-- directions enter the same source-aware state machine.
---@param joystick love.Joystick
---@param axis string
---@param value number
function FieldState:gamepadaxis(joystick, axis, value)
  if axis ~= "leftx" and axis ~= "lefty" then
    return
  end
  local source = "gamepad:" .. joystick:getID() .. ":left"
  self.runtime.input:setStickAxis(source, axis == "leftx" and "x" or "y", value)
end

---@param x number
---@param y number
---@param button integer
---@param istouch boolean?
---@param presses integer?
function FieldState:mousepressed(x, y, button, istouch, presses)
  if button == 1 then
    self.runtime.input:pointerDown("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param dx number
---@param dy number
---@param istouch boolean
function FieldState:mousemoved(x, y, dx, dy, istouch)
  if not istouch then
    self.runtime.input:pointerMove("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param button integer
---@param istouch boolean?
---@param presses integer?
function FieldState:mousereleased(x, y, button, istouch, presses)
  if button == 1 then
    self.runtime.input:pointerUp("mouse:1", x, y)
  end
end

---@param x number
---@param y number
function FieldState:wheelmoved(x, y)
  self.runtime.input:pointerScroll("mouse", x, y)
end

---@param id any
---@param x number
---@param y number
function FieldState:touchpressed(id, x, y)
  self.runtime.input:pointerDown("touch:" .. tostring(id), x, y)
end

---@param id any
---@param x number
---@param y number
function FieldState:touchmoved(id, x, y)
  self.runtime.input:pointerMove("touch:" .. tostring(id), x, y)
end

---@param id any
---@param x number
---@param y number
function FieldState:touchreleased(id, x, y)
  self.runtime.input:pointerUp("touch:" .. tostring(id), x, y)
end

function FieldState:dispose()
  if self.dialogueRenderer then
    self.dialogueRenderer:release()
    self.dialogueRenderer = nil
  end
  if self.signpostRenderer then
    self.signpostRenderer:release()
    self.signpostRenderer = nil
  end
  if self.startMenuRenderer then
    self.startMenuRenderer:release()
    self.startMenuRenderer = nil
  end
  if self.trainerCardRenderer then
    self.trainerCardRenderer:release()
    self.trainerCardRenderer = nil
  end
  if self.textRenderer then
    self.textRenderer:release()
    self.textRenderer = nil
  end
  self._lastGeometrySignature = nil
  -- Draw items borrow provider-owned GPU objects; they must not outlive the
  -- presentation residency that made those objects valid.
  self._actorRecords = nil
  self._actorDrawStorage = nil
  self._actorAssetLookup = nil
  if self.worldParts then
    self.worldParts[5] = nil
    self.worldParts[7] = nil
    self.worldParts[8] = nil
  end
  self.worldActorItems = nil
  self.spriteItems = nil
  if self.presentationActorAssets then
    for spriteId in pairs(self._presentationSpriteRefs or {}) do
      self.presentationActorAssets:release(spriteId)
    end
    self._presentationSpriteRefs = {}
    self.presentationActorAssets:dispose()
    self.presentationActorAssets = nil
  end
  if self.fieldEntranceIndicatorRenderer then
    self.fieldEntranceIndicatorRenderer:dispose()
    self.fieldEntranceIndicatorRenderer = nil
  end
  if self.fieldTerrainEffectRenderer then
    self.fieldTerrainEffectRenderer:dispose()
    self.fieldTerrainEffectRenderer = nil
  end
  if self.fieldEntranceIndicatorPool then
    self.fieldEntranceIndicatorPool:release()
    self.fieldEntranceIndicatorPool = nil
  end
  if self.fieldEmoteRenderer then
    self.fieldEmoteRenderer:dispose()
    self.fieldEmoteRenderer = nil
  end
  if self.fieldEmotePool then
    self.fieldEmotePool:release()
    self.fieldEmotePool = nil
  end
  if self.renderer then
    self.renderer:release()
    self.renderer = nil
  end
  if self.runtime then
    self.runtime:dispose()
    self.runtime = nil
  end
end

return FieldState
