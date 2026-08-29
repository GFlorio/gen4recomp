-- Normal field-runtime coordinator. It joins generated maps through
-- FieldMapLoader, drives the deterministic elevation-aware player, and
-- exposes the field warp transition lifecycle.

local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local StorageErrors = require("libs.storage.src.errors")
local Errors = require("libs.errors.src.Errors")
local DialogueLayout = require("libs.engine.src.DialogueLayout")
local FieldActorDefinitionProvider = require("libs.engine.src.FieldActorDefinitionProvider")
local AuxiliaryFieldUi = require("libs.engine.src.AuxiliaryFieldUi")
local ContextChoiceProvider = require("libs.engine.src.ContextChoiceProvider")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldApplicationHost = require("libs.engine.src.FieldApplicationHost")
local FieldApplicationIds = require("libs.engine.src.FieldApplicationIds")
local FieldApplicationRegistry = require("libs.engine.src.FieldApplicationRegistry")
local FieldCamera = require("libs.engine.src.FieldCamera")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldGrid = require("libs.engine.src.FieldGrid")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldPlayerData = require("libs.engine.src.FieldPlayerData")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldMenuHost = require("libs.engine.src.FieldMenuHost")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local FieldEventResolver = require("libs.engine.src.FieldEventResolver")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldNavigationBoundary = require("libs.engine.src.FieldNavigationBoundary")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local FieldResidencyCoordinator = require("libs.engine.src.FieldResidencyCoordinator")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FieldScripts = require("game.src.game.FieldScripts")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldSignpostController = require("libs.engine.src.FieldSignpostController")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldTerrainEffectController = require("libs.engine.src.FieldTerrainEffectController")
local FieldTerrainEffectModelFactory = require("libs.engine.src.FieldTerrainEffectModelFactory")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldWeatherCache = require("libs.assets.src.FieldWeatherCache")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local FieldWindowStyles = require("libs.engine.src.FieldWindowStyles")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldZoom = require("libs.engine.src.FieldZoom")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local MapProps = require("libs.engine.src.MapProps")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local FieldEntranceIndicatorRuntime = require("game.src.game.FieldEntranceIndicatorRuntime")
local FieldWeatherResolver = require("libs.engine.src.FieldWeatherResolver")
local StartMenuController = require("libs.engine.src.StartMenuController")
local StartMenuLayout = require("libs.engine.src.StartMenuLayout")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")
local TrainerCardController = require("libs.engine.src.TrainerCardController")
local FieldAudio = require("game.src.game.audio.FieldAudio")
local TimeOfDayProps = require("libs.engine.src.TimeOfDayProps")
local WarpSystem = require("libs.engine.src.WarpSystem")
local FieldZoneController = require("libs.engine.src.FieldZoneController")
local TargetSpawns = require("data.manifests.field_spawns")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldPlayerManifest = require("data.manifests.field_player")
local RepoFs = require("game.src.game.RepoFs")
local WindowConfig = require("game.src.WindowConfig")

local PRESENTATION_FRAME_DT = 1 / 60

local function runtimeProfileEffect(runtime, profile, phase)
  assert(type(profile) == "number", "field transition profile required")
  runtime.player.facing = phase == "enter" and runtime.transition.destinationFacing or runtime.transition.facing
end

local function runtimeCameraAdjust(runtime, profile, adjustment, player)
  assert(runtime.camera and type(runtime.camera.adjustTransition) == "function", "field transition camera required")
  if player and type(runtime.camera.setTransitionPlayer) == "function" then
    runtime.camera:setTransitionPlayer(player)
  end
  runtime.camera:adjustTransition(profile, adjustment)
end

local function runtimePanelEffect(runtime, phase)
  runtime.transitionPanel = phase
  local screen = runtime.scriptHosts and runtime.scriptHosts.screen
  if screen and type(screen.setPanelTransition) == "function" then
    screen:setPanelTransition(phase)
  end
end

local function createFieldTransition(runtime, doorAt, escalatorAt, resolveDestination)
  local function prepare(resolution, facing)
    return runtime:_prepareSwap(resolution, facing)
  end
  local function disposePrepared(resolution, prepared)
    runtime:_disposePreparedSwap(resolution, prepared)
  end
  local function commit(resolution, facing, prepared)
    runtime:_commitSwap(resolution, facing, prepared)
  end
  local function onStart(_, trigger)
    if runtime.audio then
      runtime.audio:beginWarp(trigger.warp.destinationMapId)
    end
  end
  local function playSound(soundRef)
    local audio = runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio)
    assert(audio and type(audio.play) == "function", "field transition audio host required")
    audio:play(soundRef)
  end
  local function stopSound(soundRef)
    local audio = runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio)
    assert(audio and type(audio.stop) == "function", "field transition audio host required")
    audio:stop(soundRef)
  end
  local function onProfile(profile, phase, _)
    runtimeProfileEffect(runtime, profile, phase)
  end
  local function cameraAdjust(profile, adjustment, player)
    runtimeCameraAdjust(runtime, profile, adjustment, player)
  end
  local function onPanel(phase)
    runtimePanelEffect(runtime, phase)
  end
  return FieldTransition.new({
    loader = runtime.mapLoader,
    prepare = prepare,
    disposePrepared = disposePrepared,
    commit = commit,
    doorAt = doorAt,
    escalatorAt = escalatorAt,
    resolveDestination = resolveDestination,
    onStart = onStart,
    playSound = playSound,
    stopSound = stopSound,
    onProfile = onProfile,
    cameraAdjust = cameraAdjust,
    onPanel = onPanel,
  })
end

---@class FieldRuntimeOptions
---@field resumeSave boolean?
---@field resetSave boolean?
---@field zoomConfig table?
---@field viewportWidth integer?
---@field viewportHeight integer?
---@field screenTopology ScreenTopology?
---@field saveFs SaveFs?
---@field overrideFs table? read-shaped repository filesystem override
---@field presentation boolean?
---@field scriptHosts table? deterministic host boundaries for script effects
---@field dayNight (fun(): string)? deterministic day/night source for the field-music policy
---@field audioOutput table? { audio: table, sound: table } audio-output host namespaces for the LÖVE sink (defaults to love.audio + love.sound)
---@field weatherClock table? injectable host boundary { today()->{month,day}, hasPenalty()->boolean }

---@class FieldRuntimeScriptHosts
---@field audio table?
---@field camera table?
---@field screen table?
---@field events table?

---@class FieldRuntime
---@field overrideFs table? read-shaped repository filesystem override
---@field versionId string
---@field mapIdOrSymbol string|integer?
---@field resumeSave boolean
---@field resetSave boolean
---@field viewportWidth integer
---@field viewportHeight integer
---@field screenTopology ScreenTopology?
---@field errorText string?
---@field zoom FieldZoom
---@field saveStatus string?
---@field playerData table the validated profile/options authority (FieldPlayerData shape)
---@field session FieldSession
---@field actors FieldActorManager
---@field dialogue FieldDialogueController?
---@field signpost FieldSignpostController the fixed-tick signpost controller (script-owned via ScriptSignpostHost)
---@field auxiliaryFieldUi AuxiliaryFieldUi?
---@field contextChoiceProvider ContextChoiceProvider?
---@field menuHost FieldMenuHost?
---@field actionKeys table<string, boolean>?
---@field cancelKeys table<string, boolean>?
---@field menuKeys table<string, boolean>?
---@field saveFs SaveFs?
---@field presentation boolean
---@field windowStyles FieldWindowStyles the immutable per-runtime window style catalogue
---@field scriptHosts FieldRuntimeScriptHosts?
---@field transitionPanel "exit"|"enter"|nil
---@field applications FieldApplicationRegistry the immutable per-runtime destination application catalogue
---@field applicationHost FieldApplicationHost the one application modal owner the session steps
---@field startMenuPlacement StartMenuLayout.Placement? the one Start Menu placement record rendering and pointer mapping share
---@field dayNight fun(): string?
---@field audioOutput table?
---@field audio FieldAudioController? production-composed audio service (absent when only a recording script adapter is injected, without an audio-output host)
---@field mapMusicDayNight (fun(): string)? production-composed day/night band source for the map-music lookup (present whenever the production composition exists)
---@field audioSink LoveAudioSink? production-composed LÖVE output sink (absent without an audio-output host)
---@field weatherClock table injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
---@field saveStore FieldSaveStore
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field fieldEntranceIndicatorAsset table
---@field fieldEffectAssets table
---@field physicalCoverage FieldCoverage?
---@field residency FieldResidencyCoordinator?
local FieldRuntime = {}
FieldRuntime.__index = FieldRuntime

---@class FieldRuntimePhysicalSwap
---@field coverage FieldCoverage
---@field replacement boolean
---@field previous FieldCoverage?
---@field state "prepared"|"committed"|"released"

-- The audio-output sample rate of the production composition (the mixer and
-- the LÖVE sink render at this rate, the DS SPU rate; source waves are
-- ratio-scaled, so the pitch is preserved at any output rate).
local AUDIO_SAMPLE_RATE = 32768
-- The 60 Hz sound-frame clock: FieldRuntime owns deterministic sound-frame
-- advancement independent of the field's 30 Hz simulation tick.
local AUDIO_FRAME_HZ = 60
local AUDIO_FRAME_DT = 1 / AUDIO_FRAME_HZ
local CAMERA_PROFILES_PATH = FieldCameraCache.profilesPath()
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

---@return table<string, boolean>
local function menuBindings()
  local keys = {}
  for _, key in ipairs(FieldPresentation.input and FieldPresentation.input.menu or {}) do
    keys[key] = true
  end
  return keys
end

-- The save validation set of compiled avatar ids, so a corrupt save naming an
-- unbuilt player graphic is rejected before it reaches the runtime. The set
-- comes from the generated actor index's runtime block, not a source manifest.
---@param actorIndex table
---@return table<string, boolean>
local function avatarIdSet(actorIndex)
  local set = {}
  for _, avatar in ipairs(actorIndex.runtime.avatars) do
    set[avatar.id] = true
  end
  return set
end

---@param avatars table[]
local function validateAvatarConfig(avatars)
  assert(type(avatars) == "table" and #avatars > 0, "field actor index must contain avatars")
  local genders = {}
  for _, avatar in ipairs(avatars) do
    assert(type(avatar) == "table", "field actor avatar metadata must be a table")
    assert(type(avatar.id) == "string" and avatar.id ~= "", "field actor avatar id must be a non-empty string")
    assert(
      type(avatar.spriteId) == "number" and avatar.spriteId >= 0 and avatar.spriteId % 1 == 0,
      "field actor avatar spriteId must be a non-negative integer"
    )
    assert(FieldPlayerData.GENDERS[avatar.gender] == true, "field actor avatar gender is unsupported")
    assert(genders[avatar.gender] == nil, "field actor index contains duplicate playable avatar genders")
    genders[avatar.gender] = true
  end
  for gender in pairs(FieldPlayerData.GENDERS) do
    assert(genders[gender] == true, "field actor index has no avatar for player gender " .. gender)
  end
end

---@param avatars table[]
---@param id string
---@return table
local function avatarById(avatars, id)
  assert(type(id) == "string" and id ~= "", "field avatar id must be a non-empty string")
  for index, avatar in ipairs(avatars) do
    if avatar.id == id then
      return { index = index, id = avatar.id, spriteId = avatar.spriteId, gender = avatar.gender }
    end
  end
  error("compiled avatars have no entry for " .. id, 0)
end

---@param avatars table[]
---@param gender integer
---@return table
local function avatarForGender(avatars, gender)
  assert(FieldPlayerData.GENDERS[gender] == true, "field player gender is unsupported")
  local match
  for _, avatar in ipairs(avatars) do
    if avatar.gender == gender then
      assert(match == nil, "compiled avatars contain duplicate playable gender")
      match = avatar
    end
  end
  return assert(match, "compiled avatars have no entry for player gender " .. gender)
end

local function validateScriptSave(bucket)
  return ScriptSave.validate(bucket, {})
end

-- The player consults live actors for its current logical map and source events
-- for an unloaded logical destination. The latter is a read-only preflight.
---@param candidate FieldOccupancyCandidate
---@return string?
function FieldRuntime:_playerOccupantAt(candidate)
  local currentMap = self.runtimeMap
  local coverage = currentMap.coverage
  local destinationMapId = coverage and coverage:mapHeaderAt(candidate.fieldX, candidate.fieldZ) or nil
  local occupant
  if destinationMapId == nil or destinationMapId == currentMap.mapId then
    occupant = self.actors:getAt(currentMap.mapId, candidate)
  else
    local residency = assert(self.residency, "outdoor occupancy requires logical residency")
    local destination = residency:mapForId(destinationMapId)
    if destination then
      occupant = self.actors:getAt(destinationMapId, candidate)
    else
      destination = residency:mapForPreflight(destinationMapId)
      occupant = self.actors:probeAt(destination, self.eventState, candidate)
    end
  end
  return occupant and occupant.actorId or nil
end

local function playerOccupancy(self)
  local function occupancy(candidate)
    return self:_playerOccupantAt(candidate)
  end
  return occupancy
end

-- The spawn surface at a declared spawn tile: the topmost walkable terrain
-- surface at the point, exactly the no-hint arrival rule of scripted warp
-- resolution (WarpSystem.directSurface). The historic nearest-world-Y-zero
-- choice served only the deleted (0,0) synthesis and selected the wrong floor
-- on vertically stacked maps.
local function spawnSurface(runtimeMap, localX, localZ)
  local x = localX + FieldCoordinates.TILE_CENTER_OFFSET
  local z = localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local best
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(x, z)) do
    local sample = runtimeMap.terrain:sample(plate.id, x, z)
    if best == nil or sample.worldY > best.worldY then
      best = sample
    end
  end
  assert(best, string.format("spawn tile (%d,%d) has no walkable terrain surface", localX, localZ))
  return best
end

---@return nil
local function releasePhysicalMap(_) end

---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@param context PhysicalProbeContext?
---@return table?
local function probePhysicalCell(runtimeMap, fieldX, fieldZ, context)
  return runtimeMap.coverage:probe(fieldX, fieldZ, context)
end

---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@param cellKey string
---@param sourceSurfaceId integer
---@return table
local function projectPhysicalPoint(runtimeMap, fieldX, fieldZ, cellKey, sourceSurfaceId)
  return runtimeMap.coverage:project(fieldX, fieldZ, cellKey, sourceSurfaceId)
end

---@param runtimeMap table
---@return nil
local function updateAnimated(runtimeMap)
  runtimeMap.coverage:updateAnimated()
end

---@param runtimeMap table
---@return nil
local function syncPhysicalFields(runtimeMap)
  local coverage = assert(runtimeMap.coverage)
  runtimeMap.fieldRegion = coverage.region
  runtimeMap.collision = coverage.region.collision
  runtimeMap.terrain = coverage.region.terrain
  runtimeMap.terrainDependencyHash = coverage.terrainDependencyHash
  local originX = coverage.origin.x --[[@as integer]]
  local originZ = coverage.origin.z --[[@as integer]]
  runtimeMap.coordinateOrigin = { x = originX, z = originZ }
  runtimeMap.physicalOrigin = coverage.origin
end

-- Compose the current logical context with the session-owned physical world.
-- Cached loader entries remain logical-only; this view is disposable and never
-- releases either collaborator.
local function composePhysicalMap(logicalMap, coverage)
  if not coverage then
    return logicalMap
  end
  local runtimeMap = {}
  for key, value in pairs(logicalMap) do
    runtimeMap[key] = value
  end
  runtimeMap.logicalMap = logicalMap
  runtimeMap.coverage = coverage
  runtimeMap.release = releasePhysicalMap
  runtimeMap.probePhysicalCell = probePhysicalCell
  runtimeMap.projectPhysicalPoint = projectPhysicalPoint
  runtimeMap.updateAnimated = updateAnimated
  runtimeMap.syncPhysicalFields = syncPhysicalFields
  runtimeMap:syncPhysicalFields()
  return runtimeMap
end

local function today()
  local now = os.date("*t")
  return { month = now.month, day = now.day }
end

local function hasPenalty()
  return false
end

---@return table
local function defaultWeatherClock()
  return {
    today = today,
    hasPenalty = hasPenalty,
  }
end

-- Build the non-GPU door facade used by simulation and acceptance runtimes.
-- It reads the generated scene/model contracts only to recover the source
-- door's semantic sound selector; no presentation instance is acquired.
local function headlessMapProps(runtimeMap, cacheFs)
  local scene = runtimeMap.scene
  local placements = {}
  for _, placement in ipairs(scene.buildingInstances) do
    local descriptor = assert(cacheFs:loadLua(MapAssetCache.modelPath(placement.modelKey)))
    placements[#placements + 1] = {
      placementIndex = placement.placementIndex,
      modelKey = placement.modelKey,
      transform = placement.transform,
      doorSoundType = descriptor.doorSoundType,
    }
  end
  local doorTiles = {}
  local origin = runtimeMap.coordinateOrigin
  for _, warp in ipairs(runtimeMap.fieldData.events.warps) do
    local localX, localZ = warp.x - origin.x, warp.z - origin.z
    if
      runtimeMap.collision:containsLocal(localX, localZ)
      and MetatileBehavior.isDoor(runtimeMap.collision:getLocal(localX, localZ).behavior)
    then
      doorTiles[#doorTiles + 1] = { x = localX, z = localZ }
    end
  end
  return MapProps.new({
    placements = placements,
    instances = {},
    doorTiles = doorTiles,
  })
end

function FieldRuntime.new(versionId, mapIdOrSymbol, options)
  options = options or {}
  local self = setmetatable({
    versionId = versionId,
    mapIdOrSymbol = mapIdOrSymbol or DEFAULT_MAP,
    resumeSave = options.resumeSave == true,
    resetSave = options.resetSave == true,
    viewportWidth = options.viewportWidth or WindowConfig.REFERENCE_WIDTH,
    viewportHeight = options.viewportHeight or WindowConfig.REFERENCE_HEIGHT,
    screenTopology = options.screenTopology,
    saveFs = options.saveFs,
    overrideFs = options.overrideFs,
    presentation = options.presentation == true,
    scriptHosts = options.scriptHosts,
    dayNight = options.dayNight,
    audioOutput = options.audioOutput,
    weatherClock = options.weatherClock or defaultWeatherClock(),
    errorText = nil,
    zoom = FieldZoom.new(options.zoomConfig or FieldPresentation.zoom),
    -- The 60 Hz sound-frame accumulator: wall-clock elapsed time the update
    -- loop converts into due semantic sound frames, one per complete
    -- 1/60-second interval.
    audioFrameAccumulator = 0,
    presentationFrameAccumulator = 0,
  }, FieldRuntime)
  self:_load()
  return self
end

function FieldRuntime:_load()
  -- The 60 Hz audio accumulator is transient wall-clock state and starts
  -- clean on every boot: a reset re-boots through _load, so a stale
  -- pre-reset residue must never carry into the fresh runtime.
  self.audioFrameAccumulator = 0
  self.presentationFrameAccumulator = 0
  local ok, err = pcall(FieldRuntime._loadUnchecked, self)
  -- Construction is binary: a failed boot releases everything acquired so
  -- far exactly once, then the original failure propagates to the caller.
  -- There is no half-constructed runtime; errorText never records boot
  -- failures (warp failures after a successful boot do).
  if not ok then
    self:_releaseAll()
    error(err, 0)
  end
end

function FieldRuntime:_loadCacheAndConfiguration()
  local cacheFs = CacheFs.forVersion(self.versionId)
  self.cacheFs = cacheFs
  local actorIndex = assert(
    cacheFs:loadLua(FieldActorCache.indexPath()),
    "field actor index missing -- run `scripts/buildcache.sh` first"
  )
  assert(
    actorIndex.runtime and actorIndex.runtime.avatars and actorIndex.runtime.variableSprites,
    "field actor index has no runtime configuration"
  )
  self.actorConfig = actorIndex.runtime
  validateAvatarConfig(self.actorConfig.avatars)

  local fontDef = FieldFontLoader.load(cacheFs)
  local uiManifest = assert(
    cacheFs:loadLua(FieldUiAssetCache.manifestPath()),
    "field UI cache is cold -- run `scripts/buildcache.sh` first"
  ) --[[@as FieldUiAssetCache.Manifest]]
  assert(FieldUiAssetCache.validateManifest(uiManifest), "field UI manifest is invalid")
  self.windowStyles = FieldWindowStyles.new(uiManifest)
  self.uiManifest = uiManifest
  local frameIndexes = {}
  for frame = 0, uiManifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  local playerDataContext = {
    charmap = fontDef.charmap,
    frameIndexes = frameIndexes,
  }
  local saveValidation = {
    avatars = avatarIdSet(actorIndex),
    scriptsValidate = validateScriptSave,
    playerDataContext = playerDataContext,
  }
  self.saveStore = FieldSaveStore.new(self.saveFs or SaveFs.forVersion(self.versionId), saveValidation)
  if self.resetSave then
    self.saveStore:reset()
    self.resetSave = false
    self.saveStatus = "Started a new field session"
  end

  local world =
    assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
  local profiles =
    assert(cacheFs:loadLua(CAMERA_PROFILES_PATH), "field camera cache is cold -- run `scripts/buildcache.sh` first")
  assert(profiles.schema == FieldCameraCache.SCHEMA, "unsupported field camera cache")
  self.cameraProfiles = profiles.profiles
  local weatherCatalog = assert(
    cacheFs:loadLua(FieldWeatherCache.catalogPath()),
    "field weather cache is cold -- run `scripts/buildcache.sh` first"
  ) --[[@as FieldWeatherCache.Catalog]]
  assert(FieldWeatherCache.validateCatalog(weatherCatalog), "field weather catalog is invalid")
  self.weatherCatalog = weatherCatalog
  self.fieldEntranceIndicatorAsset, self.fieldEntranceIndicator = FieldEntranceIndicatorRuntime.load(cacheFs)
  self.fieldEffectAssets = self.fieldEntranceIndicatorAsset
  self.fieldTerrainEffectController = FieldTerrainEffectController.new({
    effects = {
      tall_grass = self.fieldEntranceIndicatorAsset.effects.tall_grass,
      very_tall_grass = self.fieldEntranceIndicatorAsset.effects.very_tall_grass,
    },
    modelFactory = FieldTerrainEffectModelFactory.new(),
  })
  self.mapLoader = FieldMapLoader.new(cacheFs, world, {
    sceneLoader = self.presentation and MapSceneLoader or nil,
  })
  return cacheFs, fontDef, playerDataContext, saveValidation
end

function FieldRuntime:_mapMatrixMemberId(logicalMap)
  local mapIndex = assert(self.mapLoader.world.byId[logicalMap.mapId], "outdoor map catalog record is required")
  local mapRecord = assert(self.mapLoader.world.maps[mapIndex], "outdoor map catalog record is missing")
  return assert(mapRecord.matrix.memberId, "outdoor map matrix member is required")
end

function FieldRuntime:_composeInitialMap(logicalMap, position)
  if logicalMap.scene.type ~= "outdoor" then
    return logicalMap
  end
  assert(not self.physicalCoverage, "initial physical coverage already exists")
  self.physicalCoverage = self.mapLoader:createPhysicalCoverage(logicalMap, position)
  return composePhysicalMap(logicalMap, self.physicalCoverage)
end

function FieldRuntime:_composeCurrentMap(logicalMap, coverage)
  if logicalMap.scene.type ~= "outdoor" then
    return logicalMap
  end
  coverage = coverage or assert(self.physicalCoverage, "current outdoor coverage is required")
  assert(
    self:_mapMatrixMemberId(logicalMap) == coverage.matrixMemberId,
    "logical outdoor map does not belong to the current physical matrix"
  )
  return composePhysicalMap(logicalMap, coverage)
end

function FieldRuntime:_composePreparedMap(logicalMap, position)
  if logicalMap.scene.type ~= "outdoor" then
    return logicalMap, nil
  end
  local matrixMemberId = self:_mapMatrixMemberId(logicalMap)
  local physical = self:_stagePhysicalCoverage(logicalMap, position, matrixMemberId)
  local ok, runtimeMap = pcall(composePhysicalMap, logicalMap, physical.coverage)
  if not ok then
    if physical.replacement then
      physical.coverage:release()
      physical.state = "released"
    end
    error(runtimeMap, 0)
  end
  return runtimeMap, physical
end

function FieldRuntime:_loadMapAndRestore(playerDataContext, saveValidation)
  ---@param logicalMap RuntimeFieldMap
  ---@param position { fieldX: integer, fieldZ: integer }
  ---@return table
  local function composeRuntimeMap(logicalMap, position)
    return self:_composeInitialMap(logicalMap, position)
  end
  saveValidation.composeRuntimeMap = composeRuntimeMap
  local restored
  if self.resumeSave then
    local saved, saveErr = self.saveStore:load()
    if saved then
      local candidate, restoreErr = FieldSave.restore(saved, self.mapLoader, self.versionId, saveValidation)
      restored, saveErr = candidate, restoreErr
    end
    if saveErr and saveErr.code ~= StorageErrors.SAVE_FILE_MISSING then
      error(saveErr)
    elseif restored then
      self.saveStatus = "Resumed saved field session"
    end
  end
  self.runtimeMap = restored and restored.runtimeMap or self.mapLoader:load(self.mapIdOrSymbol)
  self.mapLoader:protectMap(self.runtimeMap.mapId, true)

  local initialPlayerData, initialPlayerDataErr = FieldPlayerData.validate(FieldPlayerManifest, playerDataContext)
  assert(initialPlayerData, "the initial player data manifest is invalid: " .. tostring(initialPlayerDataErr))
  self.playerData = restored and restored.playerData or initialPlayerData
  return restored
end

function FieldRuntime:_loadPlayerAndActors(cacheFs, restored)
  local spawn = TargetSpawns[self.runtimeMap.mapSymbol]
  assert(
    spawn == nil or (type(spawn.x) == "number" and type(spawn.z) == "number"),
    "spawn manifest must define x and z for " .. self.runtimeMap.mapSymbol
  )
  local fieldX, fieldZ, surfaceId, facing
  if restored then
    fieldX, fieldZ = restored.fieldX, restored.fieldZ
    surfaceId, facing = restored.surfaceId, restored.facing
  else
    assert(spawn, "spawn manifest must define a spawn for " .. self.runtimeMap.mapSymbol)
    if self.runtimeMap.scene.type == "outdoor" then
      fieldX = self.runtimeMap.coordinateOrigin.x + spawn.x
      fieldZ = self.runtimeMap.coordinateOrigin.z + spawn.z
      self.runtimeMap = self:_composeInitialMap(self.runtimeMap, { fieldX = fieldX, fieldZ = fieldZ })
      local spawnLocalX, spawnLocalZ = FieldCoordinates.fieldToLocal(self.runtimeMap, fieldX, fieldZ)
      surfaceId, facing = spawnSurface(self.runtimeMap, spawnLocalX, spawnLocalZ).surfaceId, spawn.facing
    else
      fieldX, fieldZ = FieldCoordinates.localToField(self.runtimeMap, spawn.x, spawn.z)
      surfaceId, facing = spawnSurface(self.runtimeMap, spawn.x, spawn.z).surfaceId, spawn.facing
    end
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
  local profile = assert(
    self.cameraProfiles[self.runtimeMap.cameraType],
    "field camera cache has no camera type " .. self.runtimeMap.cameraType
  )
  self.camera = FieldCamera.new(profile, { initialTarget = self.player:renderPosition() })
  self.viewport = FieldViewport.new(self.viewportWidth, self.viewportHeight, { mode = "expanded" })
  self:_updateCameraProjection()
  local restoredWorld = restored and restored.world
  self.eventState = FieldEventState.new(restoredWorld and {
    flags = restoredWorld.flags,
    vars = restoredWorld.variables,
  } or nil)
  self.actorAssets = FieldActorDefinitionProvider.new(cacheFs)
  self.actors = FieldActorManager.new({
    assets = self.actorAssets,
    policy = { variableSprites = self.actorConfig.variableSprites },
  })
  self.actors:enterMap(self.runtimeMap, self.eventState)
  self.avatar = restored and avatarById(self.actorConfig.avatars, restored.avatar)
    or avatarForGender(self.actorConfig.avatars, self.playerData.profile.gender)
  self.avatarAsset = self.actorAssets:acquire(self.avatar.spriteId)
  self.playerVisual = FieldPlayerVisual.new({
    player = self.player,
    spriteId = self.avatar.spriteId,
  })
  return restoredWorld
end

local function loadPreparedDestination(loader, mapId)
  local context = loader.context
  local runtime = context.runtime
  local warp = context.warp
  assert(mapId == warp.destinationMapId, "transition destination map mismatch")
  local logicalMap = runtime.mapLoader:load(mapId)
  local destinationPosition
  if warp.direct then
    destinationPosition = { fieldX = warp.x, fieldZ = warp.z }
  else
    local destinationWarp = logicalMap.fieldData.events.warps[warp.destinationWarpId + 1]
    assert(destinationWarp, "transition destination warp is missing")
    destinationPosition = { fieldX = destinationWarp.x, fieldZ = destinationWarp.z }
  end
  local composed, ownership = runtime:_composePreparedMap(logicalMap, destinationPosition)
  context.physical = ownership
  return composed
end

function FieldRuntime:_loadTransition(cacheFs, restored)
  local headlessProps = {}
  local doorAt
  local escalatorAt
  if self.presentation or self.runtimeMap.sceneRuntime or self.runtimeMap.scene then
    local function resolveDoorAt(runtimeMap, doorFieldX, doorFieldZ)
      local sceneRuntime = runtimeMap.sceneRuntime
      if sceneRuntime and sceneRuntime.mapProps then
        return sceneRuntime.mapProps:doorAt(runtimeMap, doorFieldX, doorFieldZ)
      end
      local props = headlessProps[runtimeMap.mapId]
      if not props then
        props = headlessMapProps(runtimeMap, cacheFs)
        headlessProps[runtimeMap.mapId] = props
      end
      return props:doorAt(runtimeMap, doorFieldX, doorFieldZ)
    end
    local function resolveEscalatorAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      local sceneRuntime = runtimeMap.sceneRuntime
      if sceneRuntime and sceneRuntime.mapProps then
        return sceneRuntime.mapProps:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      end
      local props = headlessProps[runtimeMap.mapId]
      if not props then
        props = headlessMapProps(runtimeMap, cacheFs)
        headlessProps[runtimeMap.mapId] = props
      end
      return props:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
    end
    doorAt = resolveDoorAt
    escalatorAt = resolveEscalatorAt
  end
  local function resolveDestination(_, sourceMap, warp)
    local context = { runtime = self, warp = warp }
    local ok, result =
      pcall(WarpSystem.resolveDestination, { load = loadPreparedDestination, context = context }, sourceMap, warp)
    if not ok then
      if context.physical and context.physical.replacement and context.physical.state == "prepared" then
        context.physical.coverage:release()
        context.physical.state = "released"
      end
      error(result, 0)
    end
    result.physical = context.physical
    return result
  end
  self.transition = createFieldTransition(self, doorAt, escalatorAt, resolveDestination)
  self.transition.player = self.player
  self.transition.suppression = restored and restored.suppression or nil
end

function FieldRuntime:_loadFieldServices(cacheFs, fontDef, restored, restoredWorld)
  local fontMetrics = FieldDialogueTheme.fontMetrics(fontDef)
  self.menuHost = FieldMenuHost.new({
    width = self.viewportWidth,
    height = self.viewportHeight,
    input = self.input,
    screenTopology = self.screenTopology,
    measureText = FieldDialogueTheme.measureText(fontDef),
  })
  local function layoutMessage(formatted)
    local result = DialogueLayout.layout(
      formatted.tokens,
      fontMetrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines, sourcePositioned = true }
    )
    result.textOriginX = FieldDialogueTheme.textInsetX
    result.textOriginY = FieldDialogueTheme.textInsetY
    result.contentWidth = FieldDialogueTheme.textWidth
    return result
  end
  local function signpostLayout(formatted)
    local result = layoutMessage(formatted)
    return { lines = (result.pages[1] or { lines = {} }).lines }
  end
  local audioService = self:_composeAudio(cacheFs, restoredWorld)
  self.dialogue = FieldDialogueController.new({
    layout = layoutMessage,
    policy = FieldPlayerData.textSpeedPolicy(self.playerData.options.textSpeed),
    audio = audioService,
  })
  self.signpost = FieldSignpostController.new({
    layout = signpostLayout,
    policy = FieldPlayerData.textSpeedPolicy(self.playerData.options.textSpeed),
  })
  self.auxiliaryFieldUi = restored and AuxiliaryFieldUi.restore(restored.auxiliaryUi) or AuxiliaryFieldUi.new()
  self.contextChoiceProvider = ContextChoiceProvider.new()
  self.actionKeys = actionBindings()
  self.cancelKeys = cancelBindings()
  self.menuKeys = menuBindings()

  local function trainerCardFactory()
    return TrainerCardController.new({
      profile = self.playerData.profile,
    })
  end
  self.applications = FieldApplicationRegistry.new({
    {
      id = FieldApplicationIds.TRAINER_CARD,
      factory = trainerCardFactory,
    },
  })
  local function menuFactory(rememberedActionId)
    return self:_composeStartMenu(rememberedActionId)
  end
  self.applicationHost = FieldApplicationHost.new({
    registry = self.applications,
    menuFactory = menuFactory,
    input = self.input,
  })
  self.startMenuPlacement = nil
  if self.screenTopology ~= nil then
    self.startMenuPlacement = StartMenuLayout.resolve(self.screenTopology, self.viewport.referenceFrame)
    self.applicationHost:setMenuPlacement(self.startMenuPlacement)
  end

  self.messageProvider = FieldMessageProvider.new(cacheFs)
  local function actorAt(mapId, candidate)
    return self.actors and self.actors:getAt(mapId, candidate) or nil
  end
  local function targetMapAt(x, z, currentMap)
    local coverage = currentMap.coverage
    if not coverage then
      return currentMap
    end
    local targetMapId = coverage:mapHeaderAt(x, z)
    if targetMapId == nil or targetMapId == currentMap.mapId then
      return currentMap
    end
    local targetMap = assert(self.residency):mapForId(targetMapId)
    return assert(targetMap, "reachable interaction target is not resident")
  end
  self.interactionResolver = FieldInteractionResolver.new({ actorAt = actorAt, targetMapAt = targetMapAt })

  local function requestStartMenuReopen()
    self.applicationHost:requestReopen()
  end
  self.scripts = FieldScripts.new({
    cacheFs = cacheFs,
    overrideFs = self.overrideFs or RepoFs.new(love.filesystem.getSourceBaseDirectory()),
    eventState = self.eventState,
    actors = self.actors,
    player = self.player,
    profile = self.playerData.profile,
    dialogue = self.dialogue,
    messageProvider = self.messageProvider,
    layout = layoutMessage,
    fontDef = fontDef,
    frameIndex = self.playerData.options.textFrame,
    signpost = self.signpost,
    windowStyles = self.windowStyles,
    transition = self.transition,
    mapLoader = self.mapLoader,
    sourceMap = self.runtimeMap,
    seedText = self.versionId .. ":" .. self.runtimeMap.mapId,
    audio = audioService,
    camera = self.scriptHosts and self.scriptHosts.camera,
    screen = self.scriptHosts and self.scriptHosts.screen,
    events = self.scriptHosts and self.scriptHosts.events,
    auxiliaryUi = self.auxiliaryFieldUi,
    contextChoice = self.contextChoiceProvider,
    menu = self.menuHost,
    startMenuReopen = { request = requestStartMenuReopen },
  })
  if restored then
    ScriptSave.restore(restored.scripts, self.scripts.scheduler, 0, {
      expectedRegistryFingerprint = self.scripts:registryFingerprint(),
    })
    self.scripts.worldState:restoreRng(restored.world)
  end
  return audioService
end

function FieldRuntime:_loadZoneAndSession()
  local function mapForId(mapId)
    return assert(self.residency):mapForId(mapId)
  end
  local function rebindScripts(runtimeMap, player)
    self.runtimeMap = runtimeMap
    player.currentMap = runtimeMap
    self.scripts:onZoneChange(runtimeMap)
  end
  local function applyWeather(runtimeMap)
    self:_applyEffectiveWeather(runtimeMap)
    self.weatherRuntime = { mapId = runtimeMap.mapId }
  end
  local function enterAudio(runtimeMap)
    if self.audio and self.audio.enterZone then
      self.audio:enterZone(runtimeMap)
    end
  end
  local function onZoneChange(change)
    self.lastZoneChange = change
  end
  self.zoneController = FieldZoneController.new({
    currentMap = self.runtimeMap,
    mapForId = mapForId,
    rebindScripts = rebindScripts,
    applyWeather = applyWeather,
    enterAudio = enterAudio,
    onChange = onZoneChange,
  })

  local function composeCurrentMap(logicalMap, coverage)
    return self:_composeCurrentMap(logicalMap, coverage)
  end
  local onPreparedMap
  if self.audio then
    local function prewarmMapMusic(runtimeMap)
      self.audio:prewarmMapMusic(runtimeMap)
    end
    onPreparedMap = prewarmMapMusic
  end
  self.residency = FieldResidencyCoordinator.new({
    coverage = self.physicalCoverage,
    mapLoader = self.mapLoader,
    actors = self.actors,
    zoneController = self.zoneController,
    eventState = self.eventState,
    composeMap = composeCurrentMap,
    onPreparedMap = onPreparedMap,
  })
  self.residency:initialize()

  local function coverageProvider()
    return self.physicalCoverage
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
    menuHost = self.menuHost,
    contextChoice = self.contextChoiceProvider,
    signpost = self.signpost,
    applicationHost = self.applicationHost,
    audio = self.audio,
    navigationBoundary = FieldNavigationBoundary.new({
      zoneController = self.zoneController,
      residencyCoordinator = self.residency,
      coverageProvider = coverageProvider,
    }),
    interactions = self.interactionResolver --[[@as FieldSession.Interactions]],
    eventResolver = FieldEventResolver,
    eventState = self.eventState,
    fieldEntranceIndicator = self.fieldEntranceIndicator,
    terrainEffects = self.fieldTerrainEffectController,
  })
end

function FieldRuntime:_loadUnchecked()
  local cacheFs, fontDef, playerDataContext, saveValidation = self:_loadCacheAndConfiguration()
  local restored = self:_loadMapAndRestore(playerDataContext, saveValidation)
  local restoredWorld = self:_loadPlayerAndActors(cacheFs, restored)
  self:_loadTransition(cacheFs, restored)
  self:_loadFieldServices(cacheFs, fontDef, restored, restoredWorld)
  self:_loadZoneAndSession()
  self:_applyEffectiveWeather(self.runtimeMap)
  self.weatherRuntime = { mapId = self.runtimeMap.mapId }
end

function FieldRuntime:_updateBackgroundTasks()
  if self.residency then
    self.residency:updatePrefetch()
  end

  -- The background registry warm-up (snapshot-miss boot) runs one time
  -- slice per frame; the first save finishes whatever it has not.
  if self.scripts.warmup then
    self.scripts.warmup:update()
  end
end

function FieldRuntime:_accumulateUpdateTime(dt)
  self.presentationFrameAccumulator = self.presentationFrameAccumulator + dt
  self.session.accumulator = self.session.accumulator + dt
  if self.audio then
    self.audioFrameAccumulator = self.audioFrameAccumulator + dt
  end
end

function FieldRuntime:_discardExcessFieldTicks(fixedDt, epsilon)
  if self.session.accumulator + epsilon >= fixedDt then
    local discarded = math.floor((self.session.accumulator + epsilon) / fixedDt)
    self.session.accumulator = self.session.accumulator - discarded * fixedDt
  end
end

function FieldRuntime:_updateAudioSink()
  -- The audio output clock: pump PCM from the engine into the host sink once
  -- per runtime update, separate from the field fixed tick (the sink never
  -- advances game-semantic audio state).
  if self.audioSink then
    self.audioSink:update()
  end
end

function FieldRuntime:_publishTransitionError()
  if self.transition.error and not self.errorText then
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
end

function FieldRuntime:_autosaveCompletedTransition()
  if self.transition:consumeCompleted() then
    self:saveSession("Autosaved after warp")
  end
end

function FieldRuntime:update(dt)
  if self.errorText then
    return
  end

  local presentationAccumulatorBefore = self.presentationFrameAccumulator
  local fieldAccumulatorBefore = self.session.accumulator
  self:_updateBackgroundTasks()
  self:_accumulateUpdateTime(dt)
  local FIXED_DT = FieldSession.FIXED_DT
  local MAX_CATCH_UP = FieldSession.MAX_CATCH_UP_TICKS
  local EPSILON = 1e-12
  local fieldExecuted = 0
  local transitionTiePresentationConsumed = false
  while true do
    local canPresentation = self.presentationFrameAccumulator + EPSILON >= PRESENTATION_FRAME_DT
    local canField = self.session.accumulator + EPSILON >= FIXED_DT and fieldExecuted < MAX_CATCH_UP
    local canAudio = self.audio ~= nil and self.audioFrameAccumulator + EPSILON >= AUDIO_FRAME_DT
    if not canPresentation and not canField and not canAudio then
      break
    end
    local nextPresentationDelta = PRESENTATION_FRAME_DT - self.presentationFrameAccumulator
    local nextFieldDelta = FIXED_DT - self.session.accumulator
    local nextAudioDelta = self.audio and AUDIO_FRAME_DT - self.audioFrameAccumulator or math.huge
    local transitionActive = self.transition.phase ~= nil and self.transition.phase ~= FieldTransition.PHASES.idle
    local transitionWinsTie = transitionActive
      and not transitionTiePresentationConsumed
      and nextPresentationDelta <= nextFieldDelta
    -- A field tick at the same timestamp starts the transition before its
    -- source-frame presentation is consumed. Once active, the presentation
    -- frame wins ties so a 30 Hz caller cannot starve the 60 Hz fade clock.
    if
      canPresentation
      and (not canField or nextPresentationDelta + EPSILON < nextFieldDelta or transitionWinsTie)
      and (not canAudio or nextPresentationDelta <= nextAudioDelta)
    then
      self.presentationFrameAccumulator = self.presentationFrameAccumulator - PRESENTATION_FRAME_DT
      self.transition:updateSourceFrame()
      if transitionWinsTie then
        transitionTiePresentationConsumed = true
      end
    elseif canField and (not canAudio or nextFieldDelta <= nextAudioDelta) then
      local transitionWasIdle = self.transition.phase == FieldTransition.PHASES.idle
      self.session.accumulator = self.session.accumulator - FIXED_DT
      self.session:updateFixed()
      fieldExecuted = fieldExecuted + 1
      if
        transitionWasIdle
        and self.transition.phase ~= FieldTransition.PHASES.idle
        and self.presentationFrameAccumulator + EPSILON >= PRESENTATION_FRAME_DT
        and PRESENTATION_FRAME_DT - presentationAccumulatorBefore + EPSILON < FIXED_DT - fieldAccumulatorBefore
      then
        -- A presentation frame before this fixed boundary belongs to the
        -- previous field state. Do not let a later frame from this same
        -- update call become the first frame of the new transition.
        self.presentationFrameAccumulator = 0
      end
      if transitionTiePresentationConsumed then
        self.presentationFrameAccumulator = 0
      end
      if self.applicationHost:error() and not self.errorText then
        self.errorText = tostring(self.applicationHost:error())
      end
      if self.errorText then
        break
      end
    else
      self.audioFrameAccumulator = self.audioFrameAccumulator - AUDIO_FRAME_DT
      self.audio:updateSoundFrame()
    end
  end
  self:_discardExcessFieldTicks(FIXED_DT, EPSILON)
  self:_updateAudioSink()
  self:_publishTransitionError()
  self:_autosaveCompletedTransition()
end

-- Every semantic-input entry point below needs the same live-input guard;
-- factored so the assertion text stays in one place. Returns the input
-- component so a call site can chain straight into it.
local function requireLiveInput(self)
  return assert(self.input, "field runtime is disposed")
end

-- Semantic input keeps the non-rendering runtime independent of keyboard and
-- gamepad event translation. Hosts drive these edges directly.
---@param direction string
function FieldRuntime:press(direction)
  requireLiveInput(self):press(direction)
end

---@param direction string
function FieldRuntime:release(direction)
  requireLiveInput(self):release(direction)
end

function FieldRuntime:pressAction()
  requireLiveInput(self):pressAction("runtime")
end

function FieldRuntime:releaseAction()
  requireLiveInput(self):releaseAction("runtime")
end

function FieldRuntime:pressCancel()
  requireLiveInput(self):pressCancel("runtime")
end

function FieldRuntime:releaseCancel()
  requireLiveInput(self):releaseCancel("runtime")
end

function FieldRuntime:pressMenu()
  requireLiveInput(self):pressMenu("runtime")
end

function FieldRuntime:releaseMenu()
  requireLiveInput(self):releaseMenu("runtime")
end

-- Helper: determine if this port has implemented the destination application
-- for an action kind.
local function implementationAvailable(self, entry)
  if entry.actionKind == "application" then
    return entry.targetApplication ~= nil and self.applications:has(entry.targetApplication)
  end
  -- Non-application actions (toggle, field_action, removed) are not yet
  -- implemented in this port.
  return false
end

-- The Start Menu composition step: build the final action list from the
-- authoritative world-state unlock flags (read through FieldScriptSymbols,
-- never raw numbers) and the registered destination capabilities. The source
-- policy produces source-present entries; the runtime separates source
-- enablement from implementation capability and combines them to set the final
-- enabled state. Construct the controller with the selection remembered
-- across a child-application round trip. Return nil only when no source-present
-- actions exist; disabled entries are visible and remain in the menu.
---@param rememberedActionId string?
---@return StartMenuController? nil when the source has no present actions
function FieldRuntime:_composeStartMenu(rememberedActionId)
  local world = self.scripts.worldState
  local flags = FieldScriptSymbols.flagsByName

  -- Source policy: returns all present actions (regardless of implementation)
  local sourceEntries = StartMenuPolicy.actions({
    hasPokedex = world:isFlagSet(flags.FLAG_GOT_POKEDEX),
    hasStarter = world:isFlagSet(flags.FLAG_GOT_STARTER),
    bagUnlocked = world:isFlagSet(flags.FLAG_GOT_BAG),
    hasPokegear = world:isFlagSet(flags.FLAG_GOT_POKEGEAR),
    trainerCardUnlocked = world:isFlagSet(flags.FLAG_GOT_TRAINER_CARD),
    saveUnlocked = world:isFlagSet(flags.FLAG_GOT_SAVE_BUTTON),
    optionsUnlocked = world:isFlagSet(flags.FLAG_GOT_OPTIONS_BUTTON),
  })

  if #sourceEntries == 0 then
    return nil
  end

  -- Compose source policy with implementation capability: set enabled to
  -- true only when both source-enabled AND implementation-available.
  local entries = {}
  for index, source in ipairs(sourceEntries) do
    entries[index] = {
      id = source.id,
      displayPosition = source.displayPosition,
      actionKind = source.actionKind,
      targetApplication = source.targetApplication,
      enabled = source.sourceEnabled and implementationAvailable(self, source),
    }
  end

  return StartMenuController.new({
    entries = entries,
    slots = self.uiManifest.startMenu.slots,
    cursorFrames = self.uiManifest.startMenu.cursor.frames,
    rememberedActionId = rememberedActionId,
  })
end

local function defaultMapMusicDayNight()
  return TimeOfDayProps.bandForHour(os.date("*t").hour) == "nite" and "night" or "day"
end

-- The production audio composition and the script audio service are
-- independent axes: the composition is constructed when no recording
-- script audio adapter is injected OR an audio-output host is explicitly
-- provided (a recording adapter then stays the script service while the
-- production renderer/output composition still exists). FieldAudio.compose
-- wires the whole engine stack (AudioAssetProvider -> VoiceMixer ->
-- SequencePlayer -> GameSound -> FieldAudioController), supplies the cry
-- boundary (CryPlayer plays the referenced cry through the same engine
-- audio), and builds the LÖVE sink over the injected audio-output host
-- boundary (acceptance fakes it; production defaults to the love.audio +
-- love.sound namespaces, and a host with no audio module has no sink to
-- pump). The caller consumes only the composed service and sink; the
-- FieldAudioController owns the map music/soundplate field policy through
-- enterMap, resolving each map's music through the injected
-- fieldDataForMap lookup. The day/night source defaults to the wall-clock
-- IsNighttime predicate (hours 0-3 and 20-23, the bandForHour nite band);
-- tests and hosts inject a deterministic one.
---@param cacheFs CacheFs
---@param restoredWorld table? the restored save's world bucket, when resuming
---@return table audioService the GameSound instance, or the injected recording adapter
function FieldRuntime:_composeAudio(cacheFs, restoredWorld)
  local audioService = self.scriptHosts and self.scriptHosts.audio
  if audioService == nil or self.audioOutput ~= nil then
    self.mapMusicDayNight = self.dayNight or defaultMapMusicDayNight
    local world =
      assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
    local function fieldPosition()
      return self.player.fieldX, self.player.fieldZ
    end
    local function fieldDataForMap(mapIdOrSymbol)
      local mapId = mapIdOrSymbol
      if type(mapIdOrSymbol) == "string" then
        mapId = world.bySymbol and world.bySymbol[mapIdOrSymbol]
      end
      if mapId == nil then
        error("unknown map symbol " .. tostring(mapIdOrSymbol))
      end
      local mapData = cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId))
      if type(mapData) ~= "table" then
        error("missing field data for map " .. tostring(mapIdOrSymbol) .. " (" .. tostring(mapId) .. ")")
      end
      if mapData.schema ~= FieldMapDataCache.FIELD_SCHEMA then
        error("field data schema mismatch for map " .. tostring(mapId))
      end
      if mapData.mapId ~= mapId then
        error("field data mapId mismatch for map " .. tostring(mapId))
      end
      return mapData
    end
    local audio = FieldAudio.compose({
      cacheFs = cacheFs,
      outputRate = AUDIO_SAMPLE_RATE,
      eventState = self.eventState,
      ---@diagnostic disable-next-line: missing-return-value -- the narrower audio contract returns fieldX,fieldZ; the runtime provider is sufficient
      fieldPosition = fieldPosition,
      dayNight = self.mapMusicDayNight,
      fieldDataForMap = fieldDataForMap,
      outputHost = self.audioOutput,
    })
    self.audio = audio.service
    self.audioSink = audio.sink
    if audioService == nil then
      audioService = self.audio
    end
    -- Initialize the FieldAudioController with the current map.
    -- Fresh boot: no override. Resume: restore the persisted override.
    self.audio:enterMap(self.runtimeMap, {
      play = true,
      restoredMusicOverride = restoredWorld and restoredWorld.fieldMusicOverride or nil,
    })
  end
  assert(audioService ~= nil, "field runtime audio composition must produce a service")
  return audioService
end

function FieldRuntime:_saveSessionUnchecked()
  local world = self.scripts.worldState:capture()
  if self.audio then
    world.fieldMusicOverride = self.audio:musicOverride()
  end
  local session = self.session --[[@as FieldSave.Session]]
  self.saveStore:save(FieldSave.capture(session, {
    avatarId = self.avatar.id,
    world = world,
    scriptsBucket = ScriptSave.capture(self.scripts.scheduler, self.session.tick, {
      registryFingerprint = self.scripts:registryFingerprint(),
    }),
    auxiliaryUi = self.auxiliaryFieldUi:capture(),
    playerData = self.playerData,
  }))
end

-- Save the current field session (developer F1 bind, autosave after warp, and
-- disposal). The save boundary presents only expected save/storage failures
-- (the structured SAVE_*/FIELD_SAVE_* errors the UI shows as save status); any
-- other failure inside the capture/write is a programming fault and rethrows
-- instead of being flattened into friendly text.
---@param successText string?
---@return boolean saved
function FieldRuntime:saveSession(successText)
  local session = self.session --[[@as FieldSave.Session?]]
  if not session or not FieldSave.canCapture(session) then
    self.saveStatus = "Save deferred: movement or transition is active"
    return false
  end
  local ok, err = pcall(FieldRuntime._saveSessionUnchecked, self)
  if not ok then
    if Errors.is(err) then
      self.saveStatus = "Save failed: " .. tostring(err)
      return false
    end
    error(err, 0)
  end
  self.saveStatus = successText or "Field session saved"
  return true
end

function FieldRuntime:_resetSave()
  self.saveStore:reset()
end

-- Reset the field session (developer F2 bind): wipe the save store, release
-- every owned collaborator, and re-boot a fresh session. Expected storage
-- failures present as saveStatus; programming faults rethrow.
function FieldRuntime:reset()
  local ok, err = pcall(FieldRuntime._resetSave, self)
  if not ok then
    if Errors.is(err) then
      self.saveStatus = "Reset failed: " .. tostring(err)
      return
    end
    error(err, 0)
  end
  self:_releaseAll()
  self.resumeSave = false
  self.errorText = nil
  self.saveStatus = "Field session reset"
  self:_load()
end

-- Apply effective weather to a runtime map: resolve the catalog rules
-- against the injected date/penalty and event state, store
-- effectiveWeatherId for headless inspection, and select the fog preset
-- (base scene fog when unchanged, catalog preset otherwise).
function FieldRuntime:_applyEffectiveWeather(runtimeMap)
  local base = runtimeMap.scene.weatherId
  local date = self.weatherClock:today()
  local penaltyActive = self.weatherClock:hasPenalty()
  local effective = FieldWeatherResolver.resolve(self.weatherCatalog, {
    mapId = runtimeMap.mapId,
    baseWeatherId = base,
    eventState = self.eventState,
    date = date,
    hasPenalty = penaltyActive,
  })
  runtimeMap.effectiveWeatherId = effective
  if runtimeMap.sceneRuntime then
    if effective == base then
      runtimeMap.sceneRuntime.fog = runtimeMap.scene.fog
    else
      runtimeMap.sceneRuntime.fog = assert(self.weatherCatalog.presets[effective])
    end
  end
end

-- Select the physical owner for a discontinuous outdoor destination. A
-- matching matrix is reusable only when its resident window is centered on
-- the destination cell; otherwise the new owner remains transition-owned
-- until the prepared swap commits.
---@param logicalMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@param matrixMemberId integer
---@return FieldRuntimePhysicalSwap
function FieldRuntime:_stagePhysicalCoverage(logicalMap, position, matrixMemberId)
  local destinationAnchorX = math.floor(position.fieldX / FieldGrid.CELL_TILES)
  local destinationAnchorZ = math.floor(position.fieldZ / FieldGrid.CELL_TILES)
  local current = self.physicalCoverage
  if
    current
    and current.matrixMemberId == matrixMemberId
    and current.anchorX == destinationAnchorX
    and current.anchorZ == destinationAnchorZ
  then
    return {
      coverage = current,
      replacement = false,
      previous = nil,
      state = "prepared",
    }
  end

  local replacement = self.mapLoader:createPhysicalCoverage(logicalMap, position)
  return {
    coverage = replacement,
    replacement = true,
    previous = current,
    state = "prepared",
  }
end

-- Fallible warp preparation, run by FieldTransition while the source map is
-- still authoritative: construct the destination player, camera, and player
-- visual, then stage logical residency as the final ownership-bearing step.
-- The coordinator keeps the source logical world live until the hidden commit.
---@param resolution table
---@param facing FieldDirection
---@return table prepared destination player, camera, and player visual
function FieldRuntime:_prepareSwap(resolution, facing)
  assert(self.transition.fadeAlpha == 1, "field map swap must be hidden by fade")
  local runtimeMap = resolution.destinationMap
  self:_applyEffectiveWeather(runtimeMap)
  local surfaceId, worldY = resolution.surfaceId, resolution.worldY
  if runtimeMap.terrain then
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, resolution.fieldX, resolution.fieldZ)
    local surface = SurfaceResolver.new(runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    })
    surfaceId, worldY = surface.surfaceId, surface.worldY
  end
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = resolution.fieldX,
    fieldZ = resolution.fieldZ,
    surfaceId = surfaceId,
    initialWorldY = worldY,
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
  local playerVisual = FieldPlayerVisual.new({
    player = player,
    spriteId = self.avatar.spriteId,
  })
  local physical = (resolution.physical and resolution.physical.coverage) or nil
  local residency = assert(self.residency):prepareTransition(runtimeMap, physical)
  return {
    player = player,
    camera = camera,
    playerVisual = playerVisual,
    physical = resolution.physical,
    residency = residency,
  }
end

-- Dispose only transition-owned physical state. A reused coverage remains
-- owned by the runtime, while a staged replacement is released once on abort.
---@param resolution table?
---@param prepared table?
function FieldRuntime:_disposePreparedSwap(resolution, prepared)
  local residency = prepared and prepared.residency
  if residency then
    assert(self.residency):discardTransition(residency)
  end
  local physical = (prepared and prepared.physical) or (resolution and resolution.physical)
  if not physical or not physical.replacement then
    return
  end
  if physical.state == "released" or physical.state == "committed" then
    return
  end
  assert(physical.state == "prepared", "physical swap is not disposable")
  assert(physical.coverage ~= self.physicalCoverage, "staged physical coverage is already committed")
  physical.coverage:release()
  physical.state = "released"
end

-- The irreversible current-map ownership transfer, run by FieldTransition
-- only after every fallible preparation step succeeded. Logical residency is
-- published first; runtime/session pointers and physical ownership follow.
---@param resolution table
---@param prepared table
function FieldRuntime:_commitSwap(resolution, _, prepared)
  local runtimeMap = resolution.destinationMap
  local physical = (prepared and prepared.physical) or resolution.physical
  local residency = assert(prepared and prepared.residency, "prepared residency transaction required")
  assert(self.residency):commitTransition(residency)
  local previousCoverage
  if physical then
    assert(physical.state == "prepared", "physical swap is not committable")
    assert(physical.coverage, "physical swap coverage is required")
    if physical.replacement then
      assert(physical.previous == self.physicalCoverage, "physical swap source owner changed")
      previousCoverage = self.physicalCoverage
      self.physicalCoverage = physical.coverage
    else
      assert(physical.coverage == self.physicalCoverage, "reused physical coverage is not current")
    end
    assert(runtimeMap.coverage == self.physicalCoverage, "destination map coverage is not the committed owner")
    physical.state = "committed"
  end
  self.fieldTerrainEffectController:clear()

  self.runtimeMap = runtimeMap
  self.player = prepared.player
  self.transition.player = prepared.player
  self.playerVisual = prepared.playerVisual
  self.session.playerVisual = prepared.playerVisual
  self.camera = prepared.camera
  self.session.currentMap = runtimeMap
  self.zoneController.currentMap = runtimeMap
  self.session.player = prepared.player
  self.session.camera = prepared.camera
  -- The map-music policy follows the destination map through FieldAudioController.
  -- enterMap updates the policy, clears the persisted override, and starts the
  -- destination's music.
  if self.audio then
    self.audio:enterMap(runtimeMap, { clearMusicOverride = true, play = true })
  end
  self.scripts:onMapSwap(prepared.player, runtimeMap)
  if previousCoverage then
    previousCoverage:release()
  end
end

function FieldRuntime:_updateCameraProjection()
  self.zoom:resize(self.viewport.worldViewport.height)
  self.camera:setProjectionAspect(self.viewport:worldAspect())
  self.camera:setZoom(self.zoom:effectiveZoom())
end

-- Re-apply the user's zoom change to the camera projection.
function FieldRuntime:applyZoomChange()
  self:_updateCameraProjection()
end

-- Presentation geometry sync owned by the runtime: the viewport and menu
-- host geometry, the new screen topology, the one Start Menu placement
-- record (recomputed from the topology and the viewport's world reference
-- frame and handed to the application host for pointer mapping), and the
-- camera projection update together. FieldState calls this exactly once per
-- structural presentation-geometry change.
---@param width integer
---@param height integer
---@param screenTopology ScreenTopology
function FieldRuntime:resizePresentation(width, height, screenTopology)
  self.viewport:resize(width, height)
  self.menuHost:resize(width, height)
  self.menuHost:setScreenTopology(screenTopology)
  self.startMenuPlacement = StartMenuLayout.resolve(screenTopology, self.viewport.referenceFrame)
  self.applicationHost:setMenuPlacement(self.startMenuPlacement)
  self:_updateCameraProjection()
end

-- The one teardown path shared by reset and dispose: release every owned
-- collaborator exactly once and clear every owned field, so a later release
-- call is a no-op. Disposing the dialogue first is deliberate -- a half-open
-- dialogue must never be persisted, so dispose() saves against a cancelled
-- dialogue -- and the field clearing means reset never leaves a hand-picked
-- subset behind for its re-boot.
function FieldRuntime:_releaseAll()
  if self.transition then
    self:_disposePreparedSwap(self.transition.resolution, self.transition.prepared)
  end
  if self.dialogue then
    self.dialogue:dispose()
  end
  self.dialogue = nil
  if self.signpost then
    self.signpost:dispose()
  end
  self.signpost = nil
  -- The application host disposes its active controller exactly once and
  -- releases the modal input lifetime; it must run before the input is
  -- cleared below.
  if self.applicationHost then
    self.applicationHost:dispose()
  end
  self.applicationHost, self.applications, self.startMenuPlacement = nil, nil, nil
  if self.messageProvider then
    self.messageProvider:dispose()
  end
  self.messageProvider = nil
  if self.residency then
    self.residency:dispose()
  end
  self.residency = nil
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
  if self.physicalCoverage then
    self.physicalCoverage:release()
  end
  if self.mapLoader then
    self.mapLoader:release()
  end
  if self.audioSink then
    self.audioSink:release()
  end
  self.actors, self.actorAssets, self.mapLoader = nil, nil, nil
  self.audio, self.audioSink, self.mapMusicDayNight = nil, nil, nil
  self.session, self.saveStore, self.scripts = nil, nil, nil
  self.transition, self.camera, self.player, self.runtimeMap, self.physicalCoverage = nil, nil, nil, nil, nil
  self.fieldTerrainEffectController = nil
  self.fieldEffectAssets = nil
  self.fieldEntranceIndicator, self.fieldEntranceIndicatorAsset = nil, nil
  self.viewport, self.input, self.menuHost = nil, nil, nil
  self.auxiliaryFieldUi, self.contextChoiceProvider, self.interactionResolver = nil, nil, nil
  self.eventState, self.avatar, self.actorConfig, self.playerData = nil, nil, nil, nil
  self.windowStyles, self.uiManifest, self.weatherCatalog = nil, nil, nil
end

-- End the state's lifetime: persist the field session if one is live, then
-- release every owned resource exactly once through the shared teardown. This
-- is the single general disposal hook invoked by App on both state
-- replacement and application shutdown; clearing the capture-bearing fields
-- in the teardown makes a repeat call a no-op rather than a second save.
function FieldRuntime:dispose()
  -- A half-open dialogue must never be persisted; disposal cancels it cleanly
  -- before the capture (and releases it once, before the shared teardown).
  if self.dialogue then
    self.dialogue:dispose()
    self.dialogue = nil
  end
  -- The same transient gate applies to the signpost: a presented window is
  -- cancelled before the save attempt, never persisted.
  if self.signpost then
    self.signpost:dispose()
    self.signpost = nil
  end
  -- The application host owns the other transient modal (the Start Menu, an
  -- application fade, or a child application): releasing it restores the
  -- capturable idle boundary before the save attempt, so quitting mid-menu
  -- persists the world like quitting mid-dialogue does. The release is
  -- idempotent; the shared teardown below re-runs it as a no-op.
  if self.applicationHost then
    self.applicationHost:dispose()
  end
  self:saveSession("Field session saved")
  self:_releaseAll()
end

return FieldRuntime
