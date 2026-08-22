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
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldEventState = require("libs.engine.src.FieldEventState")
local LocalClock = require("libs.engine.src.LocalClock")
local PlayerData = require("libs.engine.src.PlayerData")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldMenuHost = require("libs.engine.src.FieldMenuHost")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScenario = require("libs.engine.src.FieldScenario")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FieldScripts = require("game.src.game.FieldScripts")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldSignpostController = require("libs.engine.src.FieldSignpostController")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldWindowStyles = require("libs.engine.src.FieldWindowStyles")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldZoom = require("libs.engine.src.FieldZoom")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local NeighborRing = require("libs.engine.src.NeighborRing")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local FieldWeatherCache = require("libs.assets.src.FieldWeatherCache")
local FieldWeatherResolver = require("libs.engine.src.FieldWeatherResolver")
local StartMenuController = require("libs.engine.src.StartMenuController")
local StartMenuLayout = require("libs.engine.src.StartMenuLayout")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")
local TrainerCardController = require("libs.engine.src.TrainerCardController")
local FieldAudio = require("game.src.game.audio.FieldAudio")
local TimeOfDayProps = require("libs.engine.src.TimeOfDayProps")
local TargetSpawns = require("data.manifests.field_spawns")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldScenarioManifest = require("data.manifests.field_scenario")
local FieldPlayerManifest = require("data.manifests.field_player")
local RepoFs = require("game.src.game.RepoFs")
local WindowConfig = require("game.src.WindowConfig")

---@class FieldRuntimeOptions
---@field resumeSave boolean?
---@field resetSave boolean?
---@field zoomConfig table?
---@field viewportWidth integer?
---@field viewportHeight integer?
---@field screenTopology ScreenTopology?
---@field saveFs SaveFs?
---@field presentation boolean?
---@field scriptHosts table? deterministic host boundaries for script effects
---@field dayNight (fun(): string)? deterministic day/night source for the field-music policy
---@field audioOutput table? { audio: table, sound: table } audio-output host namespaces for the LÖVE sink (defaults to love.audio + love.sound)
---@field localClock LocalClock? injectable host-local civil-time boundary
---@field weatherClock table? injectable host boundary { today()->{month,day}, hasPenalty()->boolean }

---@class FieldRuntimeScriptHosts
---@field audio table?
---@field camera table?
---@field screen table?
---@field events table?

---@class FieldRuntime
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
---@field playerData table the validated profile/options authority (PlayerData shape)
---@field session FieldSession
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
---@field applications FieldApplicationRegistry the immutable per-runtime destination application catalogue
---@field applicationHost FieldApplicationHost the one application modal owner the session steps
---@field startMenuPlacement StartMenuLayout.Placement? the one Start Menu placement record rendering and pointer mapping share
---@field dayNight fun(): string?
---@field audioOutput table?
---@field audio FieldAudioController? production-composed audio service (absent when only a recording script adapter is injected, without an audio-output host)
---@field mapMusicDayNight (fun(): string)? production-composed day/night band source for the map-music lookup (present whenever the production composition exists)
---@field audioSink LoveAudioSink? production-composed LÖVE output sink (absent without an audio-output host)
---@field localClock LocalClock the shared host-local civil-time boundary
---@field weatherClock table injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
local FieldRuntime = {}
FieldRuntime.__index = FieldRuntime

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

-- The player consults the manager's occupancy index through this predicate,
-- keyed by the map the player is on, so FieldPlayer never imports the manager.
local function playerOccupancy(self)
  return function(fieldX, fieldZ, surfaceId)
    local occupant = self.actors:getAt(self.runtimeMap.mapId, fieldX, fieldZ, surfaceId)
    return occupant and occupant.actorId or nil
  end
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

---@param localClock LocalClock
---@return table
local function defaultWeatherClock(localClock)
  return {
    today = function()
      local now = localClock:nowLocal()
      return { month = now.month, day = now.day }
    end,
    hasPenalty = function()
      return false
    end,
  }
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
    presentation = options.presentation == true,
    scriptHosts = options.scriptHosts,
    dayNight = options.dayNight,
    audioOutput = options.audioOutput,
    localClock = options.localClock or LocalClock.system(),
    weatherClock = options.weatherClock,
    errorText = nil,
    zoom = FieldZoom.new(options.zoomConfig or FieldPresentation.zoom),
    -- The 60 Hz sound-frame accumulator: wall-clock elapsed time the update
    -- loop converts into due semantic sound frames, one per complete
    -- 1/60-second interval.
    audioFrameAccumulator = 0,
  }, FieldRuntime)
  self.weatherClock = self.weatherClock or defaultWeatherClock(self.localClock)
  self:_load()
  return self
end

function FieldRuntime:_load()
  -- The 60 Hz audio accumulator is transient wall-clock state and starts
  -- clean on every boot: a reset re-boots through _load, so a stale
  -- pre-reset residue must never carry into the fresh runtime.
  self.audioFrameAccumulator = 0
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)
    self.cacheFs = cacheFs
    -- The compiled actor index carries the runtime-facing actor configuration
    -- (avatars + variable-sprite policy); a missing runtime block is a stale
    -- or foreign cache and fails the boot loudly.
    local actorIndex = assert(
      cacheFs:loadLua(FieldActorCache.indexPath()),
      "field actor index missing -- run `scripts/buildcache.sh` first"
    )
    assert(
      actorIndex.runtime and actorIndex.runtime.avatars and actorIndex.runtime.variableSprites,
      "field actor index has no runtime configuration"
    )
    self.actorConfig = actorIndex.runtime
    -- The player-data validation context: the generated field font charmap
    -- and the imported dialogue frame-index set, loaded once and injected
    -- into fresh-session construction and the save store (the same pattern
    -- as the compiled avatar set). The field-UI class is a required runtime
    -- asset: its manifest is the authority for which frame indexes resolve.
    local fontDef = FieldFontLoader.load(cacheFs)
    local uiManifest = assert(
      cacheFs:loadLua(FieldUiAssetCache.manifestPath()),
      "field UI cache is cold -- run `scripts/buildcache.sh` first"
    )
    assert(FieldUiAssetCache.validateManifest(uiManifest), "field UI manifest is invalid")
    -- The window-style catalogue is composed per runtime from the generated
    -- manifest: the production-owned built-in styles, immutable from then on.
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
    -- The one immutable save-validation policy: the compiled avatar set, the
    -- deep scripts validator, and the player-data context. Both the save
    -- store and the resume restore receive the same record, so persisted data
    -- cannot bypass any injectable validator on resume.
    local saveValidation = {
      avatars = avatarIdSet(actorIndex),
      scriptsValidate = function(bucket)
        return ScriptSave.validate(bucket, {})
      end,
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

    -- The weather catalog: fourteen fog presets and ordered override rules.
    local weatherCatalog = assert(
      cacheFs:loadLua(FieldWeatherCache.catalogPath()),
      "field weather cache is cold -- run `scripts/buildcache.sh` first"
    )
    assert(FieldWeatherCache.validateCatalog(weatherCatalog), "field weather catalog is invalid")
    self.weatherCatalog = weatherCatalog

    -- FieldMapLoader owns the simulation assets (field data, collision,
    -- terrain) through the pure asset paths for every composition. The visual
    -- scene loader and finite neighbor ring are presentation-only
    -- collaborators: a non-presentation runtime simply leaves them out.
    self.mapLoader = FieldMapLoader.new(cacheFs, world, {
      sceneLoader = self.presentation and MapSceneLoader or nil,
      neighborLoader = self.presentation and NeighborRing or nil,
    })
    local restored
    if self.resumeSave then
      local saved, saveErr = self.saveStore:load()
      if saved then
        restored, saveErr = FieldSave.restore(saved, self.mapLoader, self.versionId, saveValidation)
      end
      if saveErr and saveErr.code ~= StorageErrors.SAVE_FILE_MISSING then
        self.saveStatus = "Save ignored: " .. tostring(saveErr)
      elseif restored then
        self.saveStatus = "Resumed saved field session"
      end
    end
    self.runtimeMap = restored and restored.runtimeMap or self.mapLoader:load(self.mapIdOrSymbol)
    self.mapLoader:protectMap(self.runtimeMap.mapId, true)

    -- The player profile/options authority: a fresh session copies and
    -- validates the checked-in initial manifest; a resumed session uses the
    -- required saved player-data bucket, canonicalized by FieldSave.restore
    -- as the single resume validation boundary.
    -- This is the single authority the script platform and later dialogue
    -- presentation consume; they never re-read the manifest.
    local initialPlayerData, initialPlayerDataErr = PlayerData.validate(FieldPlayerManifest, playerDataContext)
    assert(initialPlayerData, "the initial player data manifest is invalid: " .. tostring(initialPlayerDataErr))
    self.playerData = restored and restored.playerData or initialPlayerData

    -- The spawn manifest is flat: each entry is itself the spawn record
    -- (x, z, facing). A fresh boot must declare a spawn -- a missing entry is
    -- a loud boot failure naming the map, never a synthetic (0,0) origin --
    -- and a malformed entry is a manifest bug and must fail loudly instead of
    -- dumping the player onto a blocked tile. A resumed boot places the player
    -- from the save record, which carries its own position, surface, and
    -- facing; warp destinations can be any compiled map and the game autosaves
    -- after every warp, so a resume must not require a spawn entry.
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
      fieldX, fieldZ = FieldCoordinates.localToField(self.runtimeMap, spawn.x, spawn.z)
      surfaceId, facing = spawnSurface(self.runtimeMap, spawn.x, spawn.z).surfaceId, spawn.facing
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
    local worldPoint = self.player:renderPosition()

    local profile = assert(
      self.cameraProfiles[self.runtimeMap.cameraType],
      "field camera cache has no camera type " .. self.runtimeMap.cameraType
    )
    self.camera = FieldCamera.new(profile, { initialTarget = worldPoint })
    local width, height = self.viewportWidth, self.viewportHeight
    self.viewport = FieldViewport.new(width, height, { mode = "expanded" })
    self:_updateCameraProjection()
    -- Event state: a persisted save owns the flags/vars and wins over the
    -- demo scenario. Only a fresh boot (no save) seeds the scenario. The
    -- save's world bucket carries the numeric flag/var maps in the
    -- event-state shape.
    local restoredWorld = restored and restored.world
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
      policy = { variableSprites = self.actorConfig.variableSprites },
    })
    self.actors:enterMap(self.runtimeMap, self.eventState)

    -- The player's graphic is one more compiled actor visual: it is acquired from
    -- the same reference-counted provider, and FieldPlayer keeps every bit of
    -- movement authority. A resumed save names the avatar; a fresh boot uses the
    -- scenario's configured pick. Avatar selection validates against the
    -- generated actor configuration.
    self.avatar =
      FieldScenario.avatarById(self.actorConfig.avatars, (restored and restored.avatar) or FieldScenarioManifest.avatar)
    self.avatarAsset = self.actorAssets:acquire(self.avatar.spriteId)
    self.playerVisual = FieldPlayerVisual.new({
      player = self.player,
      spriteId = self.avatar.spriteId,
    })

    -- Warp resolution is owned by WarpSystem through FieldTransition's
    -- default resolver: ordinary records follow the indexed path; scripted
    -- `direct` records carry global destination coordinates and resolve
    -- through their own branch. Fallible destination preparation runs before
    -- the commit, so a failed warp never touches current-map ownership.
    -- The door choreography resolves doors through each scene's MapProps
    -- facade: field coordinate -> building placement -> ModelInstance ->
    -- semantic door animation. Nothing Nitro leaks into the transition. The
    -- resolver is the door capability: only a presentation runtime supplies
    -- one (every presentation map carries a scene runtime), so a door-less
    -- composition is exactly "no door resolver, no door choreography" and a
    -- door-kind warp there degrades to a plain fade instead of raising.
    local doorAt
    if self.presentation then
      doorAt = function(runtimeMap, fieldX, fieldZ)
        return runtimeMap.sceneRuntime.mapProps:doorAt(runtimeMap, fieldX, fieldZ)
      end
    end
    self.transition = FieldTransition.new({
      loader = self.mapLoader,
      prepare = function(resolution, facing)
        return self:_prepareSwap(resolution, facing)
      end,
      commit = function(resolution, facing, prepared)
        self:_commitSwap(resolution, facing, prepared)
      end,
      doorAt = doorAt,
      -- FieldTransition.onStart callback invoked once per transition start:
      -- invoke field-audio pre-fade for destination music mismatch decision.
      onStart = function(sourceMap, trigger, facing)
        if self.audio then
          self.audio:beginWarp(trigger.warp.destinationMapId)
        end
      end,
      -- Stair SFX callback: FieldRuntime binds the field-audio playSound
      -- hook so stair completion (SEQ_SE_DP_KAIDAN2) emits through the
      -- production audio service.
      playSound = function(soundRef)
        if self.audio then
          self.audio:play(soundRef)
        end
      end,
    })
    self.transition.player = self.player
    self.transition.suppression = restored and restored.suppression or nil

    -- Modal dialogue is pure and fixed-tick. Runtime layout needs only the
    -- compiled font definition; presentation later owns the atlas and drawing.
    -- The text-speed cadence is captured from the player options at
    -- construction, so an open request never queries options afterwards.
    local fontMetrics = FieldDialogueTheme.fontMetrics(fontDef)
    self.menuHost = FieldMenuHost.new({
      width = self.viewportWidth,
      height = self.viewportHeight,
      input = self.input,
      screenTopology = self.screenTopology,
      measureText = FieldDialogueTheme.measureText(fontDef),
    })
    local layoutMessage = function(formatted)
      return DialogueLayout.layout(
        formatted.tokens,
        fontMetrics,
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
      )
    end
    -- The signpost window presents one 27x4-tile window: the single-window
    -- lines shape the signpost controller captures is the first page of the
    -- same paginated dialogue layout. Overflow beyond the window is the
    -- signpost text path's concern, not this adapter's.
    local signpostLayout = function(formatted)
      local result = layoutMessage(formatted)
      return { lines = (result.pages[1] or { lines = {} }).lines }
    end
    self.dialogue = FieldDialogueController.new({
      layout = layoutMessage,
      ticksPerGlyph = PlayerData.ticksPerGlyph(self.playerData.options.textSpeed),
    })
    -- The signpost controller is fixed-tick and pure; the script platform
    -- advances it once per scheduler tick through the signpost host. The
    -- text-speed cadence is captured from the player options at construction,
    -- the same single authority as the dialogue controller.
    self.signpost = FieldSignpostController.new({
      layout = signpostLayout,
      ticksPerGlyph = PlayerData.ticksPerGlyph(self.playerData.options.textSpeed),
    })
    self.auxiliaryFieldUi = restored and AuxiliaryFieldUi.restore(restored.auxiliaryUi) or AuxiliaryFieldUi.new()
    self.contextChoiceProvider = ContextChoiceProvider.new()
    self.actionKeys = actionBindings()
    self.cancelKeys = cancelBindings()
    self.menuKeys = menuBindings()

    -- The field application catalogue: the registry holds child destinations
    -- only, and the runtime registers the production destinations itself --
    -- the Trainer Card is the concrete one. Its factory copies the immutable
    -- profile fields from the authoritative player-data record into the
    -- close-input-only controller, and must return a fully usable controller
    -- or raise. The catalogue is immutable after construction; canonical
    -- unimplemented destinations get capability state, never dummy
    -- factories. The Start Menu is not a registry entry: the application
    -- host composes it through its own menu factory.
    self.applications = FieldApplicationRegistry.new({
      {
        id = FieldApplicationIds.TRAINER_CARD,
        factory = function()
          return TrainerCardController.new({
            profile = self.playerData.profile,
          })
        end,
      },
    })
    self.applicationHost = FieldApplicationHost.new({
      registry = self.applications,
      menuFactory = function(rememberedActionId)
        return self:_composeStartMenu(rememberedActionId)
      end,
      input = self.input,
    })
    -- The one Start Menu placement record: the runtime computes it from the
    -- boot topology (so pointer input works before any resize) and re-applies
    -- it on presentation-geometry changes; rendering and the host's pointer
    -- mapper consume this exact record.
    self.startMenuPlacement = nil
    if self.screenTopology ~= nil then
      self.startMenuPlacement = StartMenuLayout.resolve(self.screenTopology, self.viewport.referenceFrame)
      self.applicationHost:setMenuPlacement(self.startMenuPlacement)
    end

    -- Interaction discovery: the resolver is pure and consults the manager's
    -- occupancy index; bound interactions run through the script client and
    -- the binding audit guarantees every interactable event is bound.
    self.messageProvider = FieldMessageProvider.new(cacheFs)
    self.interactionResolver = FieldInteractionResolver.new({
      actorAt = function(mapId, fieldX, fieldZ, surfaceId)
        return self.actors and self.actors:getAt(mapId, fieldX, fieldZ, surfaceId) or nil
      end,
    })

    -- The production audio composition lives in _composeAudio: extracted out
    -- of this closure (rather than inlined here) so its module-level
    -- collaborators are not upvalues of this already large boot closure,
    -- which sits close to LuaJIT's 60-upvalue-per-function limit.
    local audioService = self:_composeAudio(cacheFs, restoredWorld)

    -- The field-script platform (the script override system): registry over
    -- the compiled cache + data/scripts/overrides, composition, mechanical
    -- bindings, scheduler, and interaction client. A resumed save reattaches
    -- its script bucket.
    -- The override files live in the repo tree outside the LÖVE source dir,
    -- so the loader reads them through the io-backed repo filesystem.
    self.scripts = FieldScripts.new({
      cacheFs = cacheFs,
      overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()),
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
      startMenuReopen = {
        request = function()
          self.applicationHost:requestReopen()
        end,
      },
    })
    -- The strict schema makes the world and scripts buckets required: a
    -- restored save always carries both, so restore is unconditional.
    if restored then
      ScriptSave.restore(restored.scripts, self.scripts.scheduler, 0, {
        expectedRegistryFingerprint = self.scripts:registryFingerprint(),
      })
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
      menuHost = self.menuHost,
      contextChoice = self.contextChoiceProvider,
      signpost = self.signpost,
      applicationHost = self.applicationHost,
      -- The session's fixed-tick audio collaborator is the production
      -- GameSound only; a recording script adapter is a script service, not
      -- a session collaborator.
      audio = self.audio,
      interactions = {
        resolve = function(_, snapshot)
          return self.interactionResolver:resolve(snapshot)
        end,
      },
    })

    self:_applyEffectiveWeather(self.runtimeMap)
  end)
  -- Construction is binary: a failed boot releases everything acquired so
  -- far exactly once, then the original failure propagates to the caller.
  -- There is no half-constructed runtime; errorText never records boot
  -- failures (warp failures after a successful boot do).
  if not ok then
    self:_releaseAll()
    error(err, 0)
  end
end

function FieldRuntime:update(dt)
  if self.errorText then
    return
  end

  -- The background registry warm-up (snapshot-miss boot) runs one time
  -- slice per frame; the first save finishes whatever it has not.
  if self.scripts.warmup then
    self.scripts.warmup:update()
  end
  if self.audio then
    self.audioFrameAccumulator = self.audioFrameAccumulator + dt
    self.session.accumulator = self.session.accumulator + dt
    local FIXED_DT = FieldSession.FIXED_DT
    local MAX_CATCH_UP = FieldSession.MAX_CATCH_UP_TICKS
    local EPSILON = 1e-12
    local fieldExecuted = 0
    while true do
      local canField = self.session.accumulator + EPSILON >= FIXED_DT and fieldExecuted < MAX_CATCH_UP
      local canAudio = self.audioFrameAccumulator + EPSILON >= AUDIO_FRAME_DT
      if not canField and not canAudio then
        break
      end
      local nextFieldDelta = FIXED_DT - self.session.accumulator
      local nextAudioDelta = AUDIO_FRAME_DT - self.audioFrameAccumulator
      if canField and (not canAudio or nextFieldDelta <= nextAudioDelta) then
        self.session.accumulator = self.session.accumulator - FIXED_DT
        self.session:updateFixed()
        fieldExecuted = fieldExecuted + 1
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
    if self.session.accumulator + EPSILON >= FIXED_DT then
      local discarded = math.floor((self.session.accumulator + EPSILON) / FIXED_DT)
      self.session.accumulator = self.session.accumulator - discarded * FIXED_DT
    end
  else
    self.session:update(dt)
    if self.applicationHost:error() and not self.errorText then
      self.errorText = tostring(self.applicationHost:error())
    end
  end

  -- The audio output clock: pump PCM from the engine into the host sink once
  -- per runtime update, separate from the field fixed tick (the sink never
  -- advances game-semantic audio state).
  if self.audioSink then
    self.audioSink:update()
  end
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
  if self.transition:consumeCompleted() then
    self:saveSession("Autosaved after warp")
  end
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
    self.mapMusicDayNight = self.dayNight
      or function()
        return TimeOfDayProps.bandForHour(self.localClock:nowLocal().hour) == "nite" and "night" or "day"
      end
    local world =
      assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
    local audio = FieldAudio.compose({
      cacheFs = cacheFs,
      outputRate = AUDIO_SAMPLE_RATE,
      eventState = self.eventState,
      ---@diagnostic disable-next-line: missing-return-value -- the narrower audio contract returns fieldX,fieldZ; the runtime provider is sufficient
      fieldPosition = function()
        return self.player.fieldX, self.player.fieldZ
      end,
      dayNight = self.mapMusicDayNight,
      fieldDataForMap = function(mapIdOrSymbol)
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
      end,
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

-- Save the current field session (developer F1 bind, autosave after warp, and
-- disposal). The save boundary presents only expected save/storage failures
-- (the structured SAVE_*/FIELD_SAVE_* errors the UI shows as save status); any
-- other failure inside the capture/write is a programming fault and rethrows
-- instead of being flattened into friendly text.
---@param successText string?
---@return boolean saved
function FieldRuntime:saveSession(successText)
  if not self.session or not FieldSave.canCapture(self.session) then
    self.saveStatus = "Save deferred: movement or transition is active"
    return false
  end
  local ok, err = pcall(function()
    -- Capture the persisted field-music override from the audio controller:
    -- world.fieldMusicOverride is game state, not transient playback.
    local world = self.scripts.worldState:capture()
    if self.audio then
      world.fieldMusicOverride = self.audio:musicOverride()
    end
    self.saveStore:save(FieldSave.capture(self.session, {
      avatarId = self.avatar.id,
      scenario = FieldScenarioManifest.id,
      world = world,
      scriptsBucket = ScriptSave.capture(self.scripts.scheduler, self.session.tick, {
        registryFingerprint = self.scripts:registryFingerprint(),
      }),
      auxiliaryUi = self.auxiliaryFieldUi:capture(),
      playerData = self.playerData,
    }))
  end)
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

-- Reset the field session (developer F2 bind): wipe the save store, release
-- every owned collaborator, and re-boot a fresh session. Expected storage
-- failures present as saveStatus; programming faults rethrow.
function FieldRuntime:reset()
  local ok, err = pcall(function()
    self.saveStore:reset()
  end)
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
  local hasPenalty = self.weatherClock:hasPenalty()
  local effective = FieldWeatherResolver.resolve(self.weatherCatalog, {
    mapId = runtimeMap.mapId,
    baseWeatherId = base,
    eventState = self.eventState,
    date = date,
    hasPenalty = hasPenalty,
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

-- Fallible warp preparation, run by FieldTransition while the source map is
-- still the authoritative current map: construct the destination player and
-- camera and player visual, then enter the
-- destination actors last. Every earlier step is pure construction and
-- enterMap is internally transactional, so a failure at any point aborts the
-- transition with the source map's ownership untouched.
---@param resolution table
---@param facing FieldDirection
---@return table prepared destination player, camera, and player visual
function FieldRuntime:_prepareSwap(resolution, facing)
  assert(self.transition.fadeAlpha == 1, "field map swap must be hidden by fade")
  local runtimeMap = resolution.destinationMap
  self:_applyEffectiveWeather(runtimeMap)
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
  local playerVisual = FieldPlayerVisual.new({
    player = player,
    spriteId = self.avatar.spriteId,
  })
  self.actors:enterMap(runtimeMap, self.eventState)
  return {
    player = player,
    camera = camera,
    playerVisual = playerVisual,
  }
end

-- The irreversible current-map ownership transfer, run by FieldTransition
-- only after every fallible preparation step succeeded: actor source
-- removal, map protection transfer, and the runtime/session pointer
-- updates. A fault here is a fatal programming error; there is no
-- transition-level rollback of partially committed state.
---@param resolution table
---@param facing FieldDirection
---@param prepared table
function FieldRuntime:_commitSwap(resolution, facing, prepared)
  local runtimeMap = resolution.destinationMap
  local previousMapId = self.runtimeMap.mapId
  if runtimeMap.mapId ~= previousMapId then
    self.actors:leaveMap(previousMapId)
    self.mapLoader:protectMap(runtimeMap.mapId, true)
    self.mapLoader:protectMap(previousMapId, false)
  end

  self.runtimeMap = runtimeMap
  self.player = prepared.player
  self.transition.player = prepared.player
  self.playerVisual = prepared.playerVisual
  self.session.playerVisual = prepared.playerVisual
  self.camera = prepared.camera
  self.session.currentMap = runtimeMap
  self.session.player = prepared.player
  self.session.camera = prepared.camera
  -- The map-music policy follows the destination map through FieldAudioController.
  -- enterMap updates the policy, clears the persisted override, and starts the
  -- destination's music.
  if self.audio then
    self.audio:enterMap(runtimeMap, { clearMusicOverride = true, play = true })
  end
  self.scripts:onMapSwap(prepared.player, runtimeMap)
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
  if self.audioSink then
    self.audioSink:release()
  end
  self.actors, self.actorAssets, self.mapLoader = nil, nil, nil
  self.audio, self.audioSink, self.mapMusicDayNight = nil, nil, nil
  self.session, self.saveStore, self.scripts = nil, nil, nil
  self.transition, self.camera, self.player, self.runtimeMap = nil, nil, nil, nil
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
