-- Normal field-runtime coordinator. It joins generated maps through
-- FieldMapLoader, drives the deterministic elevation-aware player, and
-- exposes the field warp transition lifecycle.

local CacheFs = require("libs.rom.src.CacheFs")
local DialogueLayout = require("libs.engine.src.DialogueLayout")
local FieldActorAssetProvider = require("libs.engine.src.FieldActorAssetProvider")
local FieldActorDraw = require("libs.engine.src.FieldActorDraw")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldCamera = require("libs.engine.src.FieldCamera")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local PreScriptInteractionAdapter = require("libs.engine.src.PreScriptInteractionAdapter")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScenario = require("libs.engine.src.FieldScenario")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldZoom = require("libs.engine.src.FieldZoom")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapRenderer = require("libs.engine.src.MapRenderer")
local TargetSpawns = require("data.manifests.field_spawns")
local FieldActorManifest = require("data.manifests.field_actors")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldScenarioManifest = require("data.manifests.field_scenario")
local PreScriptInteractions = require("data.manifests.pre_script_interactions")

---@class FieldState
---@field versionId string
---@field idOrSymbol string|integer?
---@field resumeSave boolean
---@field resetSave boolean
---@field errorText string?
---@field zoom FieldZoom
---@field saveStatus string?
---@field session FieldSession?
---@field dialogue FieldDialogueController?
---@field dialogueRenderer FieldDialogueRenderer?
---@field actionKeys table<string, boolean>?
---@field cancelKeys table<string, boolean>?
local FieldState = {}
FieldState.__index = FieldState

local CAMERA_PROFILES_PATH = "data/generated/field/camera/profiles.lua"
local DEFAULT_MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local KEY_DIRECTIONS = {
  w = "north", up = "north",
  s = "south", down = "south",
  a = "west", left = "west",
  d = "east", right = "east",
}

---@return table<string, boolean>
local function actionBindings()
  local keys = {}
  for _, key in ipairs(FieldPresentation.input and FieldPresentation.input.action or {}) do
    keys[key] = true
  end
  return keys
end

---@return table<string, boolean>
local function cancelBindings()
  local keys = {}
  for _, key in ipairs(FieldPresentation.input and FieldPresentation.input.cancel or {}) do
    keys[key] = true
  end
  return keys
end

-- The player consults the manager's occupancy index through this predicate,
-- keyed by the map the player is on, so FieldPlayer never imports the manager.
local function playerOccupancy(self)
  return function(fieldX, fieldZ, surfaceId)
    if not self.actors then return nil end
    local occupant = self.actors:getAt(self.runtimeMap.mapId, fieldX, fieldZ, surfaceId)
    return occupant and occupant.actorId or nil
  end
end

local function initialSurface(runtimeMap, localX, localZ)
  local x, z = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local best
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(x, z)) do
    local sample = runtimeMap.terrain:sample(plate.id, x, z)
    if not best or math.abs(sample.worldY) < math.abs(best.worldY)
      or (math.abs(sample.worldY) == math.abs(best.worldY) and sample.surfaceId < best.surfaceId) then
      best = sample
    end
  end
  assert(best, string.format("spawn tile (%d,%d) has no terrain surface", localX, localZ))
  return best
end

local function terrainEnvelope(terrain)
  local minY, maxY = math.huge, -math.huge
  for _, plate in ipairs(terrain.plates) do
    if plate.walkable ~= false then
      local corners = {
        { plate.minX, plate.minZ }, { plate.maxX, plate.minZ },
        { plate.maxX, plate.maxZ }, { plate.minX, plate.maxZ },
      }
      for _, point in ipairs(corners) do
        local y = terrain:sampleHeight(plate.id, point[1], point[2])
        minY, maxY = math.min(minY, y), math.max(maxY, y)
      end
    end
  end
  assert(minY <= maxY, "field terrain has no walkable height envelope")
  return { minY = minY, maxY = maxY }
end

function FieldState.new(versionId, idOrSymbol, options)
  options = options or {}
  local self = setmetatable({
    versionId = versionId,
    idOrSymbol = idOrSymbol or DEFAULT_MAP,
    resumeSave = options.resumeSave == true,
    resetSave = options.resetSave == true,
    errorText = nil,
    zoom = FieldZoom.new(options.zoomConfig or FieldPresentation.zoom),
  }, FieldState)
  self:_load()
  return self
end

function FieldState:_load()
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)
    self.saveStore = FieldSaveStore.new(cacheFs)
    if self.resetSave then
      self.saveStore:reset()
      self.resetSave = false
      self.saveStatus = "Started a new field session"
    end
    local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()),
      "world.lua missing -- run `scripts/buildcache.sh` first")
    local profiles = assert(cacheFs:loadLua(CAMERA_PROFILES_PATH),
      "field camera cache is cold -- run `scripts/buildcache.sh` first")
    assert(profiles.schema == "g4-field-camera-profiles-v1", "unsupported field camera cache")
    self.cameraProfiles = profiles.profiles

    self.mapLoader = FieldMapLoader.new(cacheFs, world)
    local restored
    if self.resumeSave then
      local saved, saveErr = self.saveStore:load()
      if saved then
        restored, saveErr = FieldSave.restore(saved, self.mapLoader, self.versionId)
      end
      if saveErr and saveErr.code ~= "CACHE_FILE_MISSING" then
        self.saveStatus = "Save ignored: " .. tostring(saveErr)
      elseif restored then
        self.saveStatus = "Resumed saved field session"
      end
    end
    self.runtimeMap = restored and restored.runtimeMap or self.mapLoader:load(self.idOrSymbol)
    self.mapLoader:protectMap(self.runtimeMap.mapId, true)
    self.runtime = self.runtimeMap.sceneRuntime
    self.renderer = MapRenderer.new()

    local target = TargetSpawns[self.runtimeMap.mapSymbol] or {}
    local spawn = target.spawn or { x = 0, z = 0, facing = "south" }
    local fieldX, fieldZ, surfaceId, facing
    if restored then
      fieldX, fieldZ = restored.fieldX, restored.fieldZ
      surfaceId, facing = restored.surfaceId, restored.facing
    else
      fieldX, fieldZ = FieldCoordinates.localToField(self.runtimeMap, spawn.x, spawn.z)
      surfaceId, facing = initialSurface(self.runtimeMap, spawn.x, spawn.z).surfaceId, spawn.facing
    end
    self.player = FieldPlayer.new({
      currentMap = self.runtimeMap,
      fieldX = fieldX, fieldZ = fieldZ,
      surfaceId = surfaceId, facing = facing,
      occupancy = playerOccupancy(self),
    })
    self.actor = self.player
    self.input = FieldInput.new()
    self.heldDirectionKeys = {}
    local worldPoint = self.player:renderPosition()

    local profile = assert(self.cameraProfiles[self.runtimeMap.cameraType],
      "field camera cache has no camera type " .. self.runtimeMap.cameraType)
    self.camera = FieldCamera.new(profile, { initialTarget = worldPoint })
    local width, height = love.graphics.getDimensions()
    self.viewport = FieldViewport.new(width, height, { mode = "expanded" })
    self:_updateCameraProjection()
    self.envelope = terrainEnvelope(self.runtimeMap.terrain)
    self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)

    -- The event store is rebuilt from the demo scenario on every boot until the
    -- save schema carries it; nothing persists event state yet.
    self.eventState = FieldEventState.new()
    FieldScenario.apply(FieldScenarioManifest, self.eventState,
      function(mapId) return cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId)) end)
    self.actorAssets = FieldActorAssetProvider.new(cacheFs)
    self.actors = FieldActorManager.new({
      assets = self.actorAssets,
      policy = {
        variableSpriteRange = FieldActorManifest.variableSpriteRange,
        variableVarBase = FieldActorManifest.variableVarBase,
      },
    })
    self.actors:enterMap(self.runtimeMap, self.eventState)

    -- The player's graphic is one more compiled actor visual: it is acquired from
    -- the same reference-counted provider, and FieldPlayer keeps every bit of
    -- movement authority.
    self.avatar = FieldScenario.avatar(FieldScenarioManifest, FieldActorManifest.avatars)
    self.avatarAsset = self.actorAssets:acquire(self.avatar.spriteId)
    self.playerVisual = FieldPlayerVisual.new({
      player = self.player,
      spriteId = self.avatar.spriteId,
      visualDef = self.avatarAsset.visual,
    })

    self.transition = FieldTransition.new({
      loader = self.mapLoader,
      swap = function(resolution, facing) self:_swapMap(resolution, facing) end,
    })
    self.transition.suppression = restored and restored.suppression or nil

    -- Modal dialogue: the controller is pure and fixed-tick; the renderer owns
    -- the compiled font def/atlas and draws inside the centered 4:3 frame.
    self.dialogueRenderer = FieldDialogueRenderer.new({ cacheFs = cacheFs })
    local fontMetrics = FieldDialogueTheme.fontMetrics(self.dialogueRenderer.fontDef)
    local layoutMessage = function(formatted)
      return DialogueLayout.layout(formatted.tokens, fontMetrics,
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines })
    end
    self.dialogue = FieldDialogueController.new({ layout = layoutMessage })
    self.actionKeys = actionBindings()
    self.cancelKeys = cancelBindings()

    -- Interaction discovery and the temporary pre-script client. The resolver
    -- is pure and consults the manager's occupancy index; the adapter is the
    -- one construction point the scripting milestone replaces (spec section
    -- 6.3).
    self.messageProvider = FieldMessageProvider.new(cacheFs)
    self.interactionResolver = FieldInteractionResolver.new({
      actorAt = function(mapId, fieldX, fieldZ, surfaceId)
        return self.actors and self.actors:getAt(mapId, fieldX, fieldZ, surfaceId) or nil
      end,
    })
    self.preScript = PreScriptInteractionAdapter.new({
      dialogue = self.dialogue,
      provider = self.messageProvider,
      layout = layoutMessage,
      fontDef = self.dialogueRenderer.fontDef,
      getActor = function(actorId)
        return self.actors and self.actors:getById(actorId) or nil
      end,
      mapMessageBank = function(mapId)
        if mapId ~= self.runtimeMap.mapId then return nil end
        return self.runtimeMap.fieldData.messageBankId
      end,
      fixtures = PreScriptInteractions,
    })

    self.session = FieldSession.new({
      versionId = self.versionId,
      currentMap = self.runtimeMap,
      actor = self.actor,
      player = self.player,
      camera = self.camera,
      transition = self.transition,
      actors = self.actors,
      playerVisual = self.playerVisual,
      dialogue = self.dialogue,
      input = self.input,
      interactions = {
        resolve = function(_, snapshot)
          return self.interactionResolver:resolve(snapshot)
        end,
        consume = function(_, intent)
          return self.preScript:consume(intent)
        end,
      },
      coverage = function()
        self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
      end,
    })
  end)
  if not ok then
    self.errorText = tostring(err)
    self:_release()
  end
end

function FieldState:update(dt)
  if self.session then
    self.session:update(dt)
    if self.transition.error then
      local warp = self.transition.sourceWarp
      self.errorText = string.format("%s\nsource map %s warp %s -> map %s warp %s",
        tostring(self.transition.error), tostring(self.transition.sourceMap.mapId),
        tostring(warp.index), tostring(warp.destinationMapId),
        tostring(warp.destinationWarpId))
    end
    if self.transition:consumeCompleted() then self:_save("Autosaved after warp") end
  end
end

function FieldState:_save(successText)
  if not self.session or not FieldSave.canCapture(self.session) then
    self.saveStatus = "Save deferred: movement or transition is active"
    return false
  end
  local ok, err = pcall(function()
    self.saveStore:save(FieldSave.capture(self.session))
  end)
  if not ok then
    self.saveStatus = "Save failed: " .. tostring(err)
    return false
  end
  self.saveStatus = successText or "Field session saved"
  return true
end

function FieldState:_reset()
  local ok, err = pcall(function() self.saveStore:reset() end)
  if not ok then
    self.saveStatus = "Reset failed: " .. tostring(err)
    return
  end
  self:_release()
  self.session, self.transition, self.camera, self.player, self.actor = nil, nil, nil, nil, nil
  self.runtimeMap, self.runtime, self.viewport, self.saveStore = nil, nil, nil, nil
  self.resumeSave = false
  self.errorText = nil
  self.saveStatus = "Field session reset"
  self:_load()
end

function FieldState:_swapMap(resolution, facing)
  assert(self.transition.fadeAlpha == 1, "field map swap must be hidden by fade")
  local runtimeMap = resolution.destinationMap
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = resolution.fieldX,
    fieldZ = resolution.fieldZ,
    surfaceId = resolution.surfaceId,
    facing = facing,
    occupancy = playerOccupancy(self),
  })
  local profile = assert(self.cameraProfiles[runtimeMap.cameraType],
    "field camera cache has no camera type " .. runtimeMap.cameraType)
  local camera = FieldCamera.new(profile, { initialTarget = player:renderPosition() })
  camera:setProjectionAspect(self.viewport:worldAspect())
  camera:setZoom(self.zoom:effectiveZoom())

  local previousMapId = self.runtimeMap.mapId
  self.actors:enterMap(runtimeMap, self.eventState)
  if runtimeMap.mapId ~= previousMapId then self.actors:leaveMap(previousMapId) end

  self.runtimeMap = runtimeMap
  self.runtime = runtimeMap.sceneRuntime
  self.player = player
  self.actor = player
  self.playerVisual = FieldPlayerVisual.new({
    player = player,
    spriteId = self.avatar.spriteId,
    visualDef = self.avatarAsset.visual,
  })
  self.session.playerVisual = self.playerVisual
  self.camera = camera
  self.envelope = terrainEnvelope(runtimeMap.terrain)
  self.session.currentMap = runtimeMap
  self.session.player = player
  self.session.actor = player
  self.session.camera = camera
  self.mapLoader:updateCoverage(runtimeMap, camera, self.envelope)
end

function FieldState:_updateCameraProjection()
  self.zoom:resize(self.viewport.worldViewport.height)
  self.camera:setProjectionAspect(self.viewport:worldAspect())
  self.camera:setZoom(self.zoom:effectiveZoom())
end

function FieldState:_applyZoomChange()
  self:_updateCameraProjection()
  self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
end

-- Every actor the frame draws: the ROM-derived player billboard first, then the
-- object actors the manager considers present. Records stay presentation-neutral;
-- FieldActorDraw turns them into world draw items against the resident visuals.
function FieldState:_actorDraws(alpha)
  local records = { self.playerVisual:drawRecord(alpha) }
  for _, record in ipairs(self.actors:drawRecords(alpha)) do records[#records + 1] = record end
  return FieldActorDraw.items(records, function(spriteId)
    return self.actorAssets:resident(spriteId)
  end)
end

function FieldState:_worldDraws(alpha)
  local list = self:_actorDraws(alpha)
  if self.runtimeMap.coverageRuntime then
    for _, draw in ipairs(self.runtimeMap.coverageRuntime.draws) do list[#list + 1] = draw end
  end
  return list
end

function FieldState:draw()
  local lg = love.graphics
  if self.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Field runtime failed:", 24, 24)
    lg.printf(self.errorText, 24, 48, lg.getWidth() - 48)
    return
  end
  local width, height = lg.getDimensions()
  if self.viewport.width ~= width or self.viewport.height ~= height then
    self.viewport:resize(width, height)
    self:_updateCameraProjection()
    self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
  end
  local alpha = self.session:renderAlpha()
  self.renderer:draw(self.runtime, self.camera,
    self:_worldDraws(alpha), self.viewport, alpha)
  if self.transition and self.transition.fadeAlpha > 0 then
    local rectangle = self.viewport.worldViewport
    lg.setColor(0, 0, 0, self.transition.fadeAlpha)
    lg.rectangle("fill", rectangle.x, rectangle.y, rectangle.width, rectangle.height)
  end
  -- The dialogue UI composites after the world and the fade, inside the
  -- centered 4:3 reference frame, and before the developer HUD.
  if self.dialogue and self.dialogue:isModal() then
    self.dialogueRenderer:draw(self.dialogue, self.viewport)
  end
  self:_drawHud()
end

-- The playtest HUD: map identity, the player's field state, the save status,
-- and the controls. Everything else stays out of the frame until the real
-- game UI replaces even this.
function FieldState:_drawHud()
  local lg = love.graphics
  local lines = {
    string.format("map %d  %s", self.runtimeMap.mapId, self.runtimeMap.mapSymbol),
    string.format("player (%d,%d) y %.3f surface %d %s %s",
      self.actor.fieldX, self.actor.fieldZ, self.actor.worldY,
      self.actor.surfaceId, self.actor.facing, self.actor.motion),
    self.saveStatus or "save not written this run",
    "WASD/arrows move   Z/Space/Enter action   X/Backspace cancel   -/= zoom"
      .. "   0 reset zoom   F1 save   F2 reset   Esc quit",
  }
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 12, 12, 900, 20 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for index, line in ipairs(lines) do lg.print(line, 20, 12 + (index - 1) * 20) end
end

function FieldState:keypressed(key)
  if key == "escape" then love.event.quit(0) end
  if key == "f1" then self:_save() end
  if key == "f2" then self:_reset() return end
  if self.actionKeys and self.actionKeys[key] and self.input then
    self.input:pressAction()
  end
  if self.cancelKeys and self.cancelKeys[key] and self.input then
    self.input:pressCancel()
  end
  if key == "-" or key == "kp-" then
    self.zoom:zoomOut()
    self:_applyZoomChange()
    return
  end
  if key == "=" or key == "+" or key == "kp+" then
    self.zoom:zoomIn()
    self:_applyZoomChange()
    return
  end
  if key == "0" or key == "kp0" then
    self.zoom:reset()
    self:_applyZoomChange()
    return
  end
  local direction = KEY_DIRECTIONS[key]
  if direction and self.input then
    self.heldDirectionKeys[key] = direction
    self.input:press(direction)
  end
end

function FieldState:keyreleased(key)
  if self.actionKeys and self.actionKeys[key] and self.input then
    self.input:releaseAction()
    return
  end
  if self.cancelKeys and self.cancelKeys[key] and self.input then
    self.input:releaseCancel()
    return
  end
  local direction = self.heldDirectionKeys and self.heldDirectionKeys[key]
  if not direction or not self.input then return end
  self.heldDirectionKeys[key] = nil
  for _, heldDirection in pairs(self.heldDirectionKeys) do
    if heldDirection == direction then return end
  end
  self.input:release(direction)
end

-- Focus loss clears held and edge state so a blurred window cannot feed a
-- stale Action into the next frame's dialogue or movement (spec section 11.2).
---@param focused boolean
function FieldState:focus(focused)
  if not focused and self.input then self.input:clearAll() end
end

-- Gamepad Action is the south face button ("a") and Cancel the east face
-- button ("b"), mapped alongside the keyboard bindings (spec section 11.1).
---@param _ love.Joystick
---@param button string
function FieldState:gamepadpressed(_, button)
  if not self.input then return end
  if button == "a" then self.input:pressAction() end
  if button == "b" then self.input:pressCancel() end
end

---@param _ love.Joystick
---@param button string
function FieldState:gamepadreleased(_, button)
  if not self.input then return end
  if button == "a" then self.input:releaseAction() end
  if button == "b" then self.input:releaseCancel() end
end

function FieldState:_release()
  if self.dialogue then self.dialogue:dispose() end
  if self.dialogueRenderer then self.dialogueRenderer:release() end
  self.dialogue, self.dialogueRenderer = nil, nil
  if self.messageProvider then self.messageProvider:dispose() end
  self.messageProvider = nil
  if self.actors then self.actors:dispose() end
  if self.avatarAsset and self.actorAssets then
    self.actorAssets:release(self.avatarAsset.spriteId)
  end
  self.avatarAsset, self.playerVisual = nil, nil
  if self.actorAssets then self.actorAssets:dispose() end
  if self.renderer then self.renderer:release() end
  if self.mapLoader then self.mapLoader:release() end
  self.actors, self.actorAssets, self.renderer, self.mapLoader = nil, nil, nil, nil
end

function FieldState:quit()
  -- A half-open dialogue must never be persisted; disposal cancels it cleanly
  -- before the capture (spec section 16.3).
  if self.dialogue then self.dialogue:dispose() end
  self:_save("Field session saved on quit")
  self:_release()
end

return FieldState
