-- Game-side field-script platform construction (the script override system):
-- builds the registry from the compiled script cache plus the checked-in
-- `data/scripts/overrides` layer, the composition, the bindings manifest, the
-- full task registry, the service adapters over the game's field objects, and
-- the scheduler + interaction client the session steps. FieldState wires the
-- result into FieldSession; the pre-script fixture client remains the
-- fallback for unmapped intents.

local Bindings = require("libs.engine.src.script.Bindings")
local Composition = require("libs.engine.src.script.Composition")
local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local ScriptActorWorld = require("libs.engine.src.script.ScriptActorWorld")
local ScriptDialogueHost = require("libs.engine.src.script.ScriptDialogueHost")
local ScriptMenuHost = require("libs.engine.src.script.ScriptMenuHost")
local ScriptInteractionClient = require("libs.engine.src.script.ScriptInteractionClient")
local ScriptLoader = require("libs.engine.src.script.ScriptLoader")
local ScriptMapsService = require("libs.engine.src.script.ScriptMapsService")
local WorldState = require("libs.engine.src.script.WorldState")
local Scheduler = require("libs.engine.src.script.Scheduler")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")

local FieldScripts = {}

-- Every task implementation the runtime can create.
local TASK_MODULES = {
  "libs.engine.src.script.tasks.WaitTicksTask",
  "libs.engine.src.script.tasks.WaitInputTask",
  "libs.engine.src.script.tasks.WaitInputOrTicksTask",
  "libs.engine.src.script.tasks.DialogueTask",
  "libs.engine.src.script.tasks.MovementTask",
  "libs.engine.src.script.tasks.MovementBarrierTask",
  "libs.engine.src.script.tasks.MovementPauseTask",
  "libs.engine.src.script.tasks.FadeTask",
  "libs.engine.src.script.tasks.SoundWaitTask",
  "libs.engine.src.script.tasks.WarpTask",
  "libs.engine.src.script.tasks.ChildScriptTask",
  "libs.engine.src.script.tasks.AskYesNoTask",
  "libs.engine.src.script.tasks.StarterChoiceTask",
  "libs.engine.src.script.tasks.AuxiliaryUiTask",
  "libs.engine.src.script.tasks.ContextChoiceTask",
  "libs.engine.src.script.tasks.MenuTask",
}

-- Build the task registry with every registered task type. `actor_pause`
-- shares the movement pause implementation, scoped to one actor.
---@return TaskRegistry
local function taskRegistry()
  local registry = TaskRegistry.new()
  for _, moduleName in ipairs(TASK_MODULES) do
    local impl = require(moduleName)
    registry:register(impl.type, impl.version, impl)
  end
  local pause = require("libs.engine.src.script.tasks.MovementPauseTask")
  registry:register("actor_pause", pause.version, pause)
  return registry
end

-- Invert an id -> name reference catalog into the name -> id shape the world
-- state resolves symbolic references through.
---@param byId table<integer, string>
---@return table<string, integer>
local function invertCatalog(byId)
  local out = {}
  for id, name in pairs(byId or {}) do
    out[name] = id
  end
  return out
end

-- The player facade the script services consume: position/facing/gender/name
-- plus the mutation hooks the movement tasks use (the player can be a
-- scripted actor only while the field is locked). The facade holds the live
-- FieldPlayer by reference so map swaps can rebind it.
---@class ScriptPlayerFacade
---@field private _player FieldPlayer|nil
---@field private _profile table|nil { gender: integer, name: string }
local ScriptPlayerFacade = {}
ScriptPlayerFacade.__index = ScriptPlayerFacade

---@param player FieldPlayer
---@return ScriptPlayerFacade
local function playerFacade(player)
  return setmetatable({
    _player = player,
    _profile = nil,
  }, ScriptPlayerFacade)
end

function ScriptPlayerFacade:setPlayer(player)
  self._player = player
end

-- Wire the real player profile (gender and name) when the game owns one;
-- until then profile-dependent operations fault instead of fabricating
-- values.
---@param profile table { gender: integer, name: string }
function ScriptPlayerFacade:setProfile(profile)
  self._profile = profile
end

function ScriptPlayerFacade:position()
  local player = assert(self._player, "player facade has no live player")
  return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
end

function ScriptPlayerFacade:facing()
  local player = assert(self._player, "player facade has no live player")
  return player.facing
end

function ScriptPlayerFacade:gender()
  local profile = self._profile
  if profile == nil or profile.gender == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "no player profile is wired; gendered messages cannot resolve",
      {}
    )
  end
  return profile --[[@as { gender: integer, name: string }]].gender
end

function ScriptPlayerFacade:name()
  local profile = self._profile
  if profile == nil or profile.name == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "no player profile is wired; player-name text cannot resolve", {})
  end
  return profile --[[@as { gender: integer, name: string }]].name
end

function ScriptPlayerFacade:turn(direction)
  local player = assert(self._player, "player facade has no live player")
  player.facing = direction
end

function ScriptPlayerFacade:setPosition(position)
  local player = assert(self._player, "player facade has no live player")
  player.fieldX = position.fieldX
  player.fieldZ = position.fieldZ
  if position.worldY ~= nil then
    player.worldY = position.worldY
  end
end

---@class FieldScriptsOptions
---@field cacheFs CacheFs
---@field overrideFs table read-shaped filesystem for data/scripts/overrides
---@field bindingsManifest table
---@field eventState FieldEventState
---@field actors FieldActorManager
---@field player FieldPlayer
---@field profile table|nil { gender: integer, name: string }
---@field dialogue FieldDialogueController
---@field messageProvider FieldMessageProvider
---@field layout fun(formatted: table): table
---@field fontDef table
---@field transition FieldTransition
---@field mapLoader FieldMapLoader
---@field sourceMap RuntimeFieldMap
---@field seedText string|nil
---@field audio table|nil optional audio backend (absent -> SCRIPT_SERVICE_MISSING on use)
---@field camera table|nil optional camera backend
---@field screen table|nil optional screen backend
---@field events table|nil optional event sink
---@field auxiliaryUi AuxiliaryFieldUi logical auxiliary field UI state
---@field contextChoice ContextChoiceProvider contextual two-choice provider
---@field menu FieldMenuHost modal field menu host

---@class FieldScripts
---@field registry table
---@field composition Composition
---@field bindings table
---@field scheduler Scheduler
---@field client ScriptInteractionClient
---@field worldState WorldState
---@field dialogueHost ScriptDialogueHost
---@field mapsService ScriptMapsService
---@field menuHost ScriptMenuHost
---@field player ScriptPlayerFacade
local FieldScripts = {}
FieldScripts.__index = FieldScripts

-- opts.overrideFs: love.filesystem-shaped read access for the repo
-- `data/scripts/overrides` tree (the game mounts `data` before calling);
-- the loader enumerates overrides through the checked-in manifest.
---@param opts FieldScriptsOptions
---@return FieldScripts
function FieldScripts.new(opts)
  assert(
    type(opts) == "table"
      and opts.cacheFs
      and opts.overrideFs
      and opts.bindingsManifest
      and opts.eventState
      and opts.actors
      and opts.player,
    "field scripts require cache, overrides, bindings, world, and actors"
  )
  assert(
    opts.dialogue and opts.messageProvider and opts.layout and opts.fontDef,
    "field scripts require the dialogue stack"
  )
  assert(
    opts.transition and opts.mapLoader and opts.sourceMap and opts.auxiliaryUi and opts.menu,
    "field scripts require transition, auxiliary UI, and menu host"
  )

  local registry = ScriptLoader.buildRegistry(opts.cacheFs, opts.overrideFs)
  local composition = Composition.new(registry)
  local bindings = Bindings.new(opts.bindingsManifest)

  local worldState = WorldState.new({
    eventState = opts.eventState,
    catalogs = {
      flags = invertCatalog(require("data.reference.hgss.flags").byId),
      variables = invertCatalog(require("data.reference.hgss.vars").byId),
    },
    seed = opts.seedText or opts.cacheFs.versionId,
  })
  local player = playerFacade(opts.player)
  -- The real player profile (gender and name) is wired when the game owns
  -- one; without it, profile-dependent operations fault instead of
  -- fabricating values.
  if opts.profile ~= nil then
    player:setProfile(opts.profile)
  end
  local actors = ScriptActorWorld.new(opts.actors --[[@as ScriptActorManager]], player)
  local dialogueHost = ScriptDialogueHost.new({
    controller = opts.dialogue,
    provider = opts.messageProvider,
    layout = opts.layout,
    fontDef = opts.fontDef,
    player = player,
    world = worldState,
  })
  local mapsService = ScriptMapsService.new({
    transition = opts.transition,
    loader = opts.mapLoader,
    sourceMap = opts.sourceMap,
  })
  local menuHost = ScriptMenuHost.new({
    provider = opts.messageProvider,
    -- Standard GMM remains a distinct source. Its cache integration is
    -- supplied by the field message asset contract.
    standardMessageBank = 542,
    -- The field slice deliberately compiles only its map-local banks. Keep
    -- standard GMM entries semantic and presentable until their shared bank
    -- joins that derived asset selection; no raw ROM text enters runtime.
    standardFallback = function(messageId)
      return { text = "[" .. messageId .. "]" }
    end,
    createMenu = function(request)
      return request
    end,
  })

  local platform = setmetatable({
    registry = registry,
    composition = composition,
    bindings = bindings,
    worldState = worldState,
    dialogueHost = dialogueHost,
    mapsService = mapsService,
    menuHost = menuHost,
    player = player,
  }, FieldScripts)

  local scheduler
  local advanceAsync = function()
    opts.auxiliaryUi:advance()
    dialogueHost:advance(scheduler:currentInput())
  end
  scheduler = Scheduler.new({
    services = {
      world = worldState,
      actors = actors,
      player = player,
      dialogue = dialogueHost,
      maps = mapsService,
      -- Optional backends: an absent service faults the operation that
      -- needs it (SCRIPT_SERVICE_MISSING) instead of silently succeeding.
      -- The production game wires real audio/camera/screen/events here when
      -- those subsystems land; tests inject deterministic fakes.
      audio = opts.audio,
      camera = opts.camera,
      screen = opts.screen,
      events = opts.events,
      auxiliaryUi = opts.auxiliaryUi,
      contextChoice = opts.contextChoice,
      menu = opts.menu,
      scriptMenu = menuHost,
      advanceAsync = advanceAsync,
    },
    taskRegistry = taskRegistry(),
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  platform.scheduler = scheduler
  platform.client = ScriptInteractionClient.new({
    bindings = bindings,
    compose = function(id)
      return composition:effective(id)
    end,
    scheduler = scheduler,
  })
  return platform
end

-- Rebind the facade and warp source after a map swap (the player and the
-- current map are replaced by the transition).
---@param player FieldPlayer
---@param sourceMap RuntimeFieldMap
function FieldScripts:onMapSwap(player, sourceMap)
  self.player:setPlayer(player)
  self.mapsService:setSourceMap(sourceMap)
end

return FieldScripts
