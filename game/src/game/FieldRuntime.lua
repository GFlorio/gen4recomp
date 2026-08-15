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
local FieldApplicationRegistry = require("libs.engine.src.FieldApplicationRegistry")
local FieldCamera = require("libs.engine.src.FieldCamera")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
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
local FieldWindowStyleRegistry = require("libs.engine.src.FieldWindowStyleRegistry")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldZoom = require("libs.engine.src.FieldZoom")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local NeighborRing = require("libs.engine.src.NeighborRing")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local StartMenuController = require("libs.engine.src.StartMenuController")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")
local StartMenuRegistry = require("libs.engine.src.StartMenuRegistry")
local TrainerCardController = require("libs.engine.src.TrainerCardController")
local TrainerCardModel = require("libs.engine.src.TrainerCardModel")
local TargetSpawns = require("data.manifests.field_spawns")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldScenarioManifest = require("data.manifests.field_scenario")
local FieldPlayerManifest = require("data.manifests.field_player")
local RepoFs = require("game.src.game.RepoFs")
local WindowConfig = require("game.src.WindowConfig")
local BindingsManifest = require("data.scripts.manifests.vanilla_bindings")

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
---@field windowStyleDescriptors table[]? mod window-style descriptors registered after the built-ins and before the registry seals
---@field development boolean? product mode: developer mode exposes capability-missing canonical Start Menu actions disabled; the flag is boot configuration, never persisted in FieldSave
---@field applicationDescriptors table[]? boot-config application factories ({ id, factory }) registered before the application registry seals
---@field startMenuDescriptors table[]? boot-config mod Start Menu action descriptors registered before the start menu registry seals

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
---@field playerData table the validated profile/options authority (FieldPlayerData shape)
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
---@field windowStyles FieldWindowStyleRegistry the sealed per-runtime window style catalogue
---@field windowStyleDescriptors table[]? boot-config mod style descriptors registered before the registry seals
---@field scriptHosts FieldRuntimeScriptHosts?
---@field development boolean the product mode (boot configuration, never persisted)
---@field applicationDescriptors table[]? boot-config application factories registered before the registry seals
---@field startMenuDescriptors table[]? boot-config mod Start Menu action descriptors registered before the registry seals
---@field applications FieldApplicationRegistry the sealed per-runtime application catalogue
---@field applicationHost FieldApplicationHost the one application modal owner the session steps
---@field startMenuRegistry StartMenuRegistry the sealed per-runtime mod Start Menu action catalogue
local FieldRuntime = {}
FieldRuntime.__index = FieldRuntime

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

---@param versionId string
---@param mapIdOrSymbol string|integer|nil
---@param options FieldRuntimeOptions|nil
---@return FieldRuntime
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
    windowStyleDescriptors = options.windowStyleDescriptors,
    applicationDescriptors = options.applicationDescriptors,
    startMenuDescriptors = options.startMenuDescriptors,
    development = options.development == true,
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
    -- The window-style catalogue is composed per runtime from the same
    -- generated manifest and sealed before the script platform exists.
    -- Mod styles register after the built-ins and before the seal through
    -- the boot-config descriptors (the pre-seal registration seam).
    self.windowStyles = FieldWindowStyleRegistry.new()
    self.windowStyles:registerBuiltins(uiManifest)
    for _, descriptor in ipairs(self.windowStyleDescriptors or {}) do
      self.windowStyles:register(descriptor)
    end
    self.windowStyles:seal()
    self.uiManifest = uiManifest
    local frameIndexes = {}
    for frame = 0, uiManifest.dialogueFrames.count - 1 do
      frameIndexes[frame] = true
    end
    local playerDataContext = {
      charmap = fontDef.charmap,
      frameIndexes = frameIndexes,
    }
    self.saveStore = FieldSaveStore.new(self.saveFs or SaveFs.forVersion(self.versionId), {
      avatars = avatarIdSet(actorIndex),
      scriptsValidate = function(bucket)
        return ScriptSave.validate(bucket, {})
      end,
      playerDataContext = playerDataContext,
    })
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
        restored, saveErr = FieldSave.restore(saved, self.mapLoader, self.versionId, {
          playerDataContext = playerDataContext,
        })
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
    -- required saved player-data bucket (validated at the store boundary).
    -- This is the single authority the script platform and later dialogue
    -- presentation consume; they never re-read the manifest.
    local initialPlayerData, initialPlayerDataErr = FieldPlayerData.validate(FieldPlayerManifest, playerDataContext)
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
      ticksPerGlyph = FieldPlayerData.ticksPerGlyph(self.playerData.options.textSpeed),
    })
    -- The signpost controller is fixed-tick and pure; the script platform
    -- advances it once per scheduler tick through the signpost host. The
    -- text-speed cadence is captured from the player options at construction,
    -- the same single authority as the dialogue controller.
    self.signpost = FieldSignpostController.new({
      layout = signpostLayout,
      ticksPerGlyph = FieldPlayerData.ticksPerGlyph(self.playerData.options.textSpeed),
    })
    self.auxiliaryFieldUi = restored and AuxiliaryFieldUi.restore(restored.auxiliaryUi) or AuxiliaryFieldUi.new()
    self.contextChoiceProvider = ContextChoiceProvider.new()
    self.actionKeys = actionBindings()
    self.cancelKeys = cancelBindings()
    self.menuKeys = menuBindings()

    -- The field application catalogue: the Start Menu itself is the one
    -- concrete production application (its factory is the runtime's menu
    -- composition step); every other destination arrives through the
    -- boot-config descriptor seam. The registry seals before any dispatch,
    -- and canonical unimplemented destinations get capability state, never
    -- dummy factories. The mod Start Menu action catalogue follows the same
    -- build-then-seal lifetime.
    self.applications = FieldApplicationRegistry.new()
    self.applications:register({
      id = "start_menu",
      factory = function(rememberedActionId)
        return self:_composeStartMenu(rememberedActionId)
      end,
    })
    -- The Trainer Card viewer is the concrete destination: the
    -- production factory composes the read model from the authoritative
    -- player-data record and the close-input-only controller. The factory
    -- must return a fully usable controller or raise.
    self.applications:register({
      id = "trainer_card",
      factory = function()
        return TrainerCardController.new({
          model = TrainerCardModel.new(self.playerData),
        })
      end,
    })
    for _, descriptor in ipairs(self.applicationDescriptors or {}) do
      self.applications:register(descriptor)
    end
    self.applications:seal()
    self.startMenuRegistry = StartMenuRegistry.new({
      canonicalIds = StartMenuPolicy.canonicalOrder(),
      capacity = #uiManifest.startMenu.slots - 1,
    })
    for _, descriptor in ipairs(self.startMenuDescriptors or {}) do
      self.startMenuRegistry:register(descriptor)
    end
    self.startMenuRegistry:seal()
    self.applicationHost = FieldApplicationHost.new({
      registry = self.applications,
      input = self.input,
    })

    -- Interaction discovery: the resolver is pure and consults the manager's
    -- occupancy index; bound interactions run through the script client and
    -- the binding audit guarantees every interactable event is bound.
    self.messageProvider = FieldMessageProvider.new(cacheFs)
    self.interactionResolver = FieldInteractionResolver.new({
      actorAt = function(mapId, fieldX, fieldZ, surfaceId)
        return self.actors and self.actors:getAt(mapId, fieldX, fieldZ, surfaceId) or nil
      end,
    })

    -- The field-script platform (the script override system): registry over
    -- the compiled cache + data/scripts/overrides, composition, bindings,
    -- scheduler, and interaction client. Bound interactions run through the
    -- scheduler; the binding audit rejects unbound interactable events at
    -- construction. A resumed save reattaches its script bucket.
    -- The override files live in the repo tree outside the LÖVE source dir,
    -- so the loader reads them through the io-backed repo filesystem.
    self.scripts = FieldScripts.new({
      cacheFs = cacheFs,
      overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()),
      bindingsManifest = BindingsManifest,
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
      audio = self.scriptHosts and self.scriptHosts.audio,
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
      interactions = {
        resolve = function(_, snapshot)
          return self.interactionResolver:resolve(snapshot)
        end,
      },
    })
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
  self.session:update(dt)
  -- The application host retains factory/composition failures with the
  -- original error; the runtime surfaces them on its fatal-error channel
  -- and freezes instead of resuming field simulation.
  if self.applicationHost:error() and not self.errorText then
    self.errorText = tostring(self.applicationHost:error())
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

-- The Start Menu composition step: build the strict policy snapshot
-- from the authoritative world state and the sealed application-id set,
-- merge the sealed mod actions, resolve every label through the message
-- provider (the bank is acquired once and released on success or failure,
-- bank), and construct the controller with the product mode and the
-- selection remembered across a child-application round trip. The factory
-- must return a fully usable controller or raise.
---@param rememberedActionId string?
---@return StartMenuController
function FieldRuntime:_composeStartMenu(rememberedActionId)
  local world = self.scripts.worldState
  local flags = FieldScriptSymbols.flagsByName
  local capabilities = self.applications:ids()
  local entries = self.startMenuRegistry:compose(
    StartMenuPolicy.build({
      context = "normal_field",
      progression = {
        hasPokedex = world:isFlagSet(flags.FLAG_GOT_POKEDEX),
        hasStarter = world:isFlagSet(flags.FLAG_GOT_STARTER),
        bagUnlocked = false,
        hasPokegear = world:isFlagSet(flags.FLAG_GOT_POKEGEAR),
      },
      capabilities = capabilities,
    }),
    capabilities
  )
  local resolved = {}
  local acquiredBanks = {}
  local ok, resolveErr = pcall(function()
    local bankCache = {}
    for _, entry in ipairs(entries) do
      local bank, messageId = entry.message:match("^msg%.hgss%.(%d+)%.(%d+)$")
      assert(bank ~= nil, "start menu action labels must be message refs: " .. tostring(entry.message))
      local bankId = assert(tonumber(bank))
      local bank = bankCache[bankId]
      if bank == nil then
        local artifact, bankErr = self.messageProvider:acquireBank(bankId)
        if artifact == nil then
          local err = bankErr --[[@as Errors.Error]]
          Errors.raise(err.code, err.message, { bankId = bankId, cause = err.context })
        end
        bank = assert(artifact)
        bankCache[bankId] = bank
        acquiredBanks[#acquiredBanks + 1] = bankId
      end
      local template, err = self.messageProvider:get(bankId, tonumber(messageId))
      if not template then
        error(err, 0)
      end
      resolved[#resolved + 1] = {
        id = entry.id,
        message = template.text,
        targetApplication = entry.targetApplication,
        present = entry.present,
        vanillaEnabled = entry.vanillaEnabled,
        capabilityAvailable = entry.capabilityAvailable,
        enabled = entry.enabled,
        normalVisible = entry.normalVisible,
        developerVisible = entry.developerVisible,
        displayPosition = entry.displayPosition,
      }
    end
  end)
  for _, bankId in ipairs(acquiredBanks) do
    self.messageProvider:releaseBank(bankId)
  end
  if not ok then
    error(resolveErr, 0)
  end
  return StartMenuController.new({
    entries = resolved,
    development = self.development,
    slots = self.uiManifest.startMenu.slots,
    cursorFrames = self.uiManifest.startMenu.cursor.frames,
    rememberedActionId = rememberedActionId,
  })
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
    self.saveStore:save(FieldSave.capture(self.session, {
      avatarId = self.avatar.id,
      scenario = FieldScenarioManifest.id,
      world = self.scripts.worldState:capture(),
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

-- Presentation viewport resize owned by the runtime: the viewport and menu
-- host geometry, the new screen topology, and the camera projection update
-- together.
---@param width integer
---@param height integer
---@param screenTopology ScreenTopology
function FieldRuntime:resizePresentation(width, height, screenTopology)
  self.viewport:resize(width, height)
  self.menuHost:resize(width, height)
  self.menuHost:setScreenTopology(screenTopology)
  self.applicationHost:setScreenTopology(screenTopology)
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
  self.applicationHost, self.applications, self.startMenuRegistry = nil, nil, nil
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
  self.session, self.saveStore, self.scripts = nil, nil, nil
  self.transition, self.camera, self.player, self.runtimeMap = nil, nil, nil, nil
  self.viewport, self.input, self.menuHost = nil, nil, nil
  self.auxiliaryFieldUi, self.contextChoiceProvider, self.interactionResolver = nil, nil, nil
  self.eventState, self.avatar, self.actorConfig, self.playerData = nil, nil, nil, nil
  self.windowStyles, self.uiManifest = nil, nil
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
