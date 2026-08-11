-- Normal field-runtime coordinator. It joins generated maps through
-- FieldMapLoader, drives the deterministic elevation-aware player, and
-- exposes the field warp transition lifecycle.

local CacheFs = require("libs.rom.src.CacheFs")
local SaveFs = require("libs.rom.src.SaveFs")
local DialogueLayout = require("libs.engine.src.DialogueLayout")
local FieldActorDefinitionProvider = require("libs.engine.src.FieldActorDefinitionProvider")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldCamera = require("libs.engine.src.FieldCamera")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")
local MapCollisionLoader = require("libs.engine.src.MapCollisionLoader")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local PreScriptInteractionAdapter = require("libs.engine.src.PreScriptInteractionAdapter")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScenario = require("libs.engine.src.FieldScenario")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FieldScripts = require("game.src.game.FieldScripts")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldZoom = require("libs.engine.src.FieldZoom")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local TargetSpawns = require("data.manifests.field_spawns")
local FieldActorManifest = require("data.manifests.field_actors")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldScenarioManifest = require("data.manifests.field_scenario")
local PreScriptInteractions = require("data.manifests.pre_script_interactions")
local RepoFs = require("game.src.game.RepoFs")
local BindingsManifest = require("data.scripts.manifests.vanilla_bindings")

---@class FieldRuntimeOptions
---@field resumeSave boolean?
---@field resetSave boolean?
---@field zoomConfig table?
---@field viewportWidth integer?
---@field viewportHeight integer?
---@field saveFs SaveFs?
---@field presentation boolean?
---@field scriptHosts table? deterministic host boundaries for script effects

---@class FieldRuntimeScriptHosts
---@field audio table?
---@field camera table?
---@field screen table?
---@field events table?

---@class FieldRuntime
---@field versionId string
---@field idOrSymbol string|integer?
---@field resumeSave boolean
---@field resetSave boolean
---@field viewportWidth integer
---@field viewportHeight integer
---@field errorText string?
---@field zoom FieldZoom
---@field saveStatus string?
---@field session FieldSession?
---@field dialogue FieldDialogueController?
---@field actionKeys table<string, boolean>?
---@field cancelKeys table<string, boolean>?
---@field saveFs SaveFs?
---@field presentation boolean
---@field scriptHosts FieldRuntimeScriptHosts?
local FieldRuntime = {}
FieldRuntime.__index = FieldRuntime

local CAMERA_PROFILES_PATH = "data/generated/field/camera/profiles.lua"
local DEFAULT_MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
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

-- The save validation set of compiled avatar ids, so a corrupt save naming an
-- unbuilt player graphic is rejected before it reaches the runtime.
---@return table<string, boolean>
local function avatarIdSet()
  local set = {}
  for _, avatar in ipairs(FieldActorManifest.avatars or {}) do
    set[avatar.id] = true
  end
  return set
end

-- The player consults the manager's occupancy index through this predicate,
-- keyed by the map the player is on, so FieldPlayer never imports the manager.
local function playerOccupancy(self)
  return function(fieldX, fieldZ, surfaceId)
    if not self.actors then
      return nil
    end
    local occupant = self.actors:getAt(self.runtimeMap.mapId, fieldX, fieldZ, surfaceId)
    return occupant and occupant.actorId or nil
  end
end

local function initialSurface(runtimeMap, localX, localZ)
  local x, z = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local best
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(x, z)) do
    local sample = runtimeMap.terrain:sample(plate.id, x, z)
    if
      not best
      or math.abs(sample.worldY) < math.abs(best.worldY)
      or (math.abs(sample.worldY) == math.abs(best.worldY) and sample.surfaceId < best.surfaceId)
    then
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
        { plate.minX, plate.minZ },
        { plate.maxX, plate.minZ },
        { plate.maxX, plate.maxZ },
        { plate.minX, plate.maxZ },
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

---@param versionId string
---@param idOrSymbol string|integer|nil
---@param options FieldRuntimeOptions|nil
---@return FieldRuntime
function FieldRuntime.new(versionId, idOrSymbol, options)
  options = options or {}
  local self = setmetatable({
    versionId = versionId,
    idOrSymbol = idOrSymbol or DEFAULT_MAP,
    resumeSave = options.resumeSave == true,
    resetSave = options.resetSave == true,
    viewportWidth = options.viewportWidth or 640,
    viewportHeight = options.viewportHeight or 480,
    saveFs = options.saveFs,
    presentation = options.presentation == true,
    scriptHosts = options.scriptHosts,
    errorText = nil,
    zoom = FieldZoom.new(options.zoomConfig or FieldPresentation.zoom),
  }, FieldRuntime)
  self:_load()
  return self
end

function FieldRuntime:_load()
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)
    self.cacheFs = cacheFs
    self.saveStore = FieldSaveStore.new(self.saveFs or SaveFs.forVersion(self.versionId), { avatars = avatarIdSet() })
    if self.resetSave then
      self.saveStore:reset()
      self.resetSave = false
      self.saveStatus = "Started a new field session"
    end
    local world =
      assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
    local profiles =
      assert(cacheFs:loadLua(CAMERA_PROFILES_PATH), "field camera cache is cold -- run `scripts/buildcache.sh` first")
    assert(profiles.schema == "g4-field-camera-profiles-v1", "unsupported field camera cache")
    self.cameraProfiles = profiles.profiles

    self.mapLoader = FieldMapLoader.new(cacheFs, world, {
      sceneLoader = self.presentation and nil or MapCollisionLoader,
      coverageLoader = self.presentation and nil or {
        load = function()
          return nil
        end,
      },
    })
    local restored
    if self.resumeSave then
      local saved, saveErr = self.saveStore:load()
      if saved then
        restored, saveErr = FieldSave.restore(saved, self.mapLoader, self.versionId)
      end
      if saveErr and saveErr.code ~= "SAVE_FILE_MISSING" then
        self.saveStatus = "Save ignored: " .. tostring(saveErr)
      elseif restored then
        self.saveStatus = "Resumed saved field session"
      end
    end
    self.runtimeMap = restored and restored.runtimeMap or self.mapLoader:load(self.idOrSymbol)
    self.mapLoader:protectMap(self.runtimeMap.mapId, true)

    -- The provisional spawn manifest is flat: each entry is itself the spawn
    -- record (x, z, facing). Unmapped maps keep the historic default so any
    -- map can be booted by id; a malformed entry is a manifest bug and must
    -- fail loudly instead of dumping the player onto a blocked tile.
    local spawn = TargetSpawns[self.runtimeMap.mapSymbol]
    if not spawn then
      spawn = { x = 0, z = 0, facing = "south" }
    else
      assert(
        type(spawn.x) == "number" and type(spawn.z) == "number",
        "spawn manifest must define x and z for " .. self.runtimeMap.mapSymbol
      )
    end
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
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = surfaceId,
      facing = facing,
      occupancy = playerOccupancy(self),
    })
    self.input = FieldInput.new()
    self.heldDirectionKeys = {}
    local worldPoint = self.player:renderPosition()

    local profile = assert(
      self.cameraProfiles[self.runtimeMap.cameraType],
      "field camera cache has no camera type " .. self.runtimeMap.cameraType
    )
    self.camera = FieldCamera.new(profile, { initialTarget = worldPoint })
    local width, height = self.viewportWidth, self.viewportHeight
    self.viewport = FieldViewport.new(width, height, { mode = "expanded" })
    self:_updateCameraProjection()
    self.envelope = terrainEnvelope(self.runtimeMap.terrain)
    self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)

    -- Event state: a persisted save owns the flags/vars and wins over the
    -- demo scenario. Only a fresh boot (no save) seeds the scenario. The v2
    -- save's world bucket carries the numeric flag/var maps in the
    -- event-state shape.
    local restoredWorld = restored and restored.world or nil
    self.eventState = FieldEventState.new(restoredWorld and {
      flags = restoredWorld.flags,
      vars = restoredWorld.variables,
    } or nil)
    if not restored then
      FieldScenario.apply(FieldScenarioManifest, self.eventState, function(mapId)
        return cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId))
      end)
    end
    self.actorAssets = FieldActorDefinitionProvider.new(cacheFs)
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
    -- movement authority. A resumed save names the avatar; a fresh boot uses the
    -- scenario's configured pick.
    self.avatar = FieldScenario.avatarById(
      FieldActorManifest.avatars,
      (restored and restored.avatar) or FieldScenarioManifest.avatar
    )
    self.avatarAsset = self.actorAssets:acquire(self.avatar.spriteId)
    self.playerVisual = FieldPlayerVisual.new({
      player = self.player,
      spriteId = self.avatar.spriteId,
    })

    -- Warp resolution is owned by WarpSystem through FieldTransition's
    -- default resolver: ordinary records follow the indexed path; scripted
    -- `direct` records carry global destination coordinates and resolve
    -- through their own branch.
    self.transition = FieldTransition.new({
      loader = self.mapLoader,
      swap = function(resolution, facing)
        self:_swapMap(resolution, facing)
      end,
    })
    self.transition.suppression = restored and restored.suppression or nil

    -- Modal dialogue is pure and fixed-tick. Runtime layout needs only the
    -- compiled font definition; presentation later owns the atlas and drawing.
    local fontDef = FieldFontLoader.load(cacheFs)
    local fontMetrics = FieldDialogueTheme.fontMetrics(fontDef)
    local layoutMessage = function(formatted)
      return DialogueLayout.layout(
        formatted.tokens,
        fontMetrics,
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
      )
    end
    self.dialogue = FieldDialogueController.new({ layout = layoutMessage })
    self.actionKeys = actionBindings()
    self.cancelKeys = cancelBindings()

    -- Interaction discovery and the pre-script fallback client. The resolver
    -- is pure and consults the manager's occupancy index; the adapter remains
    -- the fallback for interactions without script bindings.
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
      fontDef = fontDef,
      getActor = function(actorId)
        return self.actors and self.actors:getById(actorId) or nil
      end,
      mapMessageBank = function(mapId)
        if mapId ~= self.runtimeMap.mapId then
          return nil
        end
        return self.runtimeMap.fieldData.messageBankId
      end,
      fixtures = PreScriptInteractions,
    })

    -- The field-script platform (the script override system): registry over
    -- the compiled cache + data/scripts/overrides, composition, bindings,
    -- scheduler, and interaction client. Bound interactions now run through
    -- the scheduler; the pre-script fixture client stays as the fallback for
    -- unmapped events. A resumed v2 save reattaches its script bucket.
    -- The override files live in the repo tree outside the LÖVE source dir,
    -- so the loader reads them through the io-backed repo filesystem.
    self.scripts = FieldScripts.new({
      cacheFs = cacheFs,
      overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()),
      bindingsManifest = BindingsManifest,
      eventState = self.eventState,
      actors = self.actors,
      player = self.player,
      dialogue = self.dialogue,
      messageProvider = self.messageProvider,
      layout = layoutMessage,
      fontDef = fontDef,
      transition = self.transition,
      mapLoader = self.mapLoader,
      sourceMap = self.runtimeMap,
      seedText = self.versionId .. ":" .. self.runtimeMap.mapId,
      audio = self.scriptHosts and self.scriptHosts.audio,
      camera = self.scriptHosts and self.scriptHosts.camera,
      screen = self.scriptHosts and self.scriptHosts.screen,
      events = self.scriptHosts and self.scriptHosts.events,
    })
    if restored and restored.scripts then
      ScriptSave.restore(restored.scripts, self.scripts.scheduler, 0, {
        expectedRegistryFingerprint = self.scripts.registry:fingerprint(),
      })
    end
    if restored and restored.world then
      self.scripts.worldState:restoreRng(restored.world)
    end

    self.session = FieldSession.new({
      versionId = self.versionId,
      currentMap = self.runtimeMap,
      player = self.player,
      camera = self.camera,
      transition = self.transition,
      actors = self.actors,
      playerVisual = self.playerVisual,
      dialogue = self.dialogue,
      input = self.input,
      scriptScheduler = self.scripts.scheduler,
      scriptClient = self.scripts.client,
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

function FieldRuntime:update(dt)
  if self.session then
    self.session:update(dt)
    if self.transition.error then
      local context = self.transition.warpContext
      if context then
        self.errorText = string.format(
          "%s\nsource map %s warp %s -> map %s warp %s",
          tostring(self.transition.error),
          tostring(context.sourceMapId),
          tostring(context.sourceWarpId),
          tostring(context.destinationMapId),
          tostring(context.destinationWarpId)
        )
      else
        self.errorText = tostring(self.transition.error)
      end
    end
    if self.transition:consumeCompleted() then
      self:_save("Autosaved after warp")
    end
  end
end

-- Semantic input keeps the non-rendering runtime independent of keyboard and
-- gamepad event translation. Hosts drive these edges directly.
---@param direction string
function FieldRuntime:press(direction)
  assert(self.input, "field runtime is not loaded")
  self.input:press(direction)
end

---@param direction string
function FieldRuntime:release(direction)
  assert(self.input, "field runtime is not loaded")
  self.input:release(direction)
end

function FieldRuntime:pressAction()
  assert(self.input, "field runtime is not loaded")
  self.input:pressAction("runtime")
end

function FieldRuntime:releaseAction()
  assert(self.input, "field runtime is not loaded")
  self.input:releaseAction("runtime")
end

function FieldRuntime:pressCancel()
  assert(self.input, "field runtime is not loaded")
  self.input:pressCancel("runtime")
end

function FieldRuntime:releaseCancel()
  assert(self.input, "field runtime is not loaded")
  self.input:releaseCancel("runtime")
end

function FieldRuntime:_save(successText)
  if not self.session or not FieldSave.canCapture(self.session) then
    self.saveStatus = "Save deferred: movement or transition is active"
    return false
  end
  local ok, err = pcall(function()
    local scriptsBucket
    if self.scripts then
      scriptsBucket = ScriptSave.capture(self.scripts.scheduler, self.session.tick, {
        registryFingerprint = self.scripts.registry:fingerprint(),
      })
    end
    self.saveStore:save(FieldSave.capture(self.session, {
      avatarId = self.avatar.id,
      scenario = FieldScenarioManifest.id,
      world = self.scripts and self.scripts.worldState:capture() or nil,
      scriptsBucket = scriptsBucket,
    }))
  end)
  if not ok then
    self.saveStatus = "Save failed: " .. tostring(err)
    return false
  end
  self.saveStatus = successText or "Field session saved"
  return true
end

function FieldRuntime:_reset()
  local ok, err = pcall(function()
    self.saveStore:reset()
  end)
  if not ok then
    self.saveStatus = "Reset failed: " .. tostring(err)
    return
  end
  self:_release()
  self.session, self.transition, self.camera, self.player = nil, nil, nil, nil
  self.runtimeMap, self.viewport, self.saveStore = nil, nil, nil
  self.resumeSave = false
  self.errorText = nil
  self.saveStatus = "Field session reset"
  self:_load()
end

function FieldRuntime:_swapMap(resolution, facing)
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
  local profile = assert(
    self.cameraProfiles[runtimeMap.cameraType],
    "field camera cache has no camera type " .. runtimeMap.cameraType
  )
  local camera = FieldCamera.new(profile, { initialTarget = player:renderPosition() })
  camera:setProjectionAspect(self.viewport:worldAspect())
  camera:setZoom(self.zoom:effectiveZoom())

  local previousMapId = self.runtimeMap.mapId
  self.actors:enterMap(runtimeMap, self.eventState)
  if runtimeMap.mapId ~= previousMapId then
    self.actors:leaveMap(previousMapId)
    self.mapLoader:protectMap(runtimeMap.mapId, true)
    self.mapLoader:protectMap(previousMapId, false)
  end

  self.runtimeMap = runtimeMap
  self.player = player
  self.playerVisual = FieldPlayerVisual.new({
    player = player,
    spriteId = self.avatar.spriteId,
  })
  self.session.playerVisual = self.playerVisual
  self.camera = camera
  self.envelope = terrainEnvelope(runtimeMap.terrain)
  self.session.currentMap = runtimeMap
  self.session.player = player
  self.session.camera = camera
  if self.scripts then
    self.scripts:onMapSwap(player, runtimeMap)
  end
  self.mapLoader:updateCoverage(runtimeMap, camera, self.envelope)
end

function FieldRuntime:_updateCameraProjection()
  self.zoom:resize(self.viewport.worldViewport.height)
  self.camera:setProjectionAspect(self.viewport:worldAspect())
  self.camera:setZoom(self.zoom:effectiveZoom())
end

function FieldRuntime:_applyZoomChange()
  self:_updateCameraProjection()
  self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
end

-- Every actor the frame draws: the ROM-derived player billboard first, then the
-- object actors the manager considers present. Records stay presentation-neutral;
-- FieldActorDraw turns them into world draw items against the resident visuals.
function FieldRuntime:_release()
  if self.dialogue then
    self.dialogue:dispose()
  end
  self.dialogue = nil
  if self.messageProvider then
    self.messageProvider:dispose()
  end
  self.messageProvider = nil
  if self.actors then
    self.actors:dispose()
  end
  if self.avatarAsset and self.actorAssets then
    self.actorAssets:release(self.avatarAsset.spriteId)
  end
  self.avatarAsset, self.playerVisual = nil, nil
  if self.actorAssets then
    self.actorAssets:dispose()
  end
  if self.mapLoader then
    self.mapLoader:release()
  end
  self.actors, self.actorAssets, self.mapLoader = nil, nil, nil
end

-- End the state's lifetime: persist the field session if one is live, then
-- release every owned resource exactly once. This is the single general
-- disposal hook invoked by App on both state replacement and application
-- shutdown; clearing the capture-bearing fields after release makes a repeat
-- call a no-op rather than a second save.
function FieldRuntime:dispose()
  -- A half-open dialogue must never be persisted; disposal cancels it cleanly
  -- before the capture (and releases it once, before _release runs).
  if self.dialogue then
    self.dialogue:dispose()
    self.dialogue = nil
  end
  self:_save("Field session saved")
  self:_release()
  self.session, self.saveStore, self.scripts = nil, nil, nil
end

return FieldRuntime
