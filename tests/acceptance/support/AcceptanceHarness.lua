-- Production-composed, non-rendering field acceptance harness. It owns an
-- isolated save namespace and a temporary graphics trap around each runtime,
-- while FieldRuntime remains the sole owner of maps, scripts, actors, and saves.

local FieldSave = require("libs.engine.src.FieldSave")
local SaveFs = require("libs.storage.src.SaveFs")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldRuntime = require("game.src.game.FieldRuntime")
local App = require("game.src.game.App")
local RecordingScriptHosts = require("tests.acceptance.support.RecordingScriptHosts")

---@class AcceptanceHarness
---@field versions string[]
---@field runtimeFactory fun(versionId: string, map: string|integer|nil, runtimeOptions: table|nil): table
---@field saveNamespace fun(versionId: string, serial: integer): string
---@field removeSaveNamespace fun(namespace: string)
local AcceptanceHarness = {}
AcceptanceHarness.__index = AcceptanceHarness

local serial = 0
local TRACE_LIMIT = 32

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function defaultNamespace(versionId, index)
  return string.format("acceptance/%s/%d", versionId, index)
end

local function removeNamespace(path)
  local fs = love.filesystem
  fs.remove(path .. "/" .. FieldSave.PATH .. ".tmp")
  fs.remove(path .. "/" .. FieldSave.PATH)
  fs.remove(path)
end

-- Acceptance owns the save-root host boundary, so it can inject one scoped
-- write failure without changing the runtime's real save composition.
local function saveBackend(faults, lifecycle)
  local fs = love.filesystem
  return {
    write = function(_, path, data)
      lifecycle.saveWrites = lifecycle.saveWrites + 1
      if faults.failWrite then
        faults.failWrite = false
        return false, "acceptance injected save write failure"
      end
      return fs.write(path, data)
    end,
    read = function(_, path)
      return fs.read(path)
    end,
    getInfo = function(_, path)
      return fs.getInfo(path)
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(path)
    end,
    remove = function(_, path)
      return fs.remove(path)
    end,
    replace = function(_, sourcePath, destinationPath)
      return os.rename(fs.getSaveDirectory() .. "/" .. sourcePath, fs.getSaveDirectory() .. "/" .. destinationPath)
    end,
  }
end

local function installRenderTrap()
  local graphics = love and love.graphics
  if not graphics then
    return { attempts = 0, restore = function() end }
  end
  local trap = { attempts = 0, original = {} }
  for _, name in ipairs({ "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw" }) do
    trap.original[name] = graphics[name]
    graphics[name] = function()
      trap.attempts = trap.attempts + 1
      error("acceptance runtime attempted love.graphics." .. name, 2)
    end
  end
  function trap:restore()
    if not self.original then
      return
    end
    for name, value in pairs(self.original) do
      graphics[name] = value
    end
    self.original = nil
  end
  return trap
end

local function abortBoot(runtime, trap, removeSaveNamespace, namespace)
  local disposeErr
  if runtime then
    local ok, err = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      disposeErr = err
    end
  end
  trap:restore()
  removeSaveNamespace(namespace)
  if disposeErr then
    error(disposeErr, 0)
  end
end

---@class AcceptanceGame
---@field runtime FieldRuntime
---@field saveNamespace string
---@field removeSaveNamespace fun(path: string)
---@field trap table
---@field timeline table[]
---@field hosts table
---@field closed boolean?
---@field runtimeDisposed boolean?
---@field disposeErr any
---@field lifecycle { saveWrites: integer, runtimeDisposals: integer }
---@field worldProbe { flags: table<integer, boolean>, variables: table<integer, integer> }
---@field faults { failWrite: boolean? }
---@field harness AcceptanceHarness
---@field versionId string
---@field map string|integer|nil
---@field fieldOptions table|nil
---@field saveStatus string?
---@field ownsNamespace boolean
local Game = {}
Game.__index = Game

function AcceptanceHarness:_newRuntime(versionId, map, namespace, save, faults, lifecycle, fieldOptions)
  local runtimeOptions = {}
  for key, value in pairs(fieldOptions or {}) do
    runtimeOptions[key] = value
  end
  runtimeOptions.saveFs = SaveFs.forVersion(versionId, saveBackend(faults, lifecycle), namespace)
  runtimeOptions.resumeSave = save == "resume"
  runtimeOptions.resetSave = save == "fresh"
  runtimeOptions.scriptHosts = RecordingScriptHosts.new()
  return self.runtimeFactory(versionId, map, runtimeOptions)
end

local function gameFor(
  harness,
  runtime,
  namespace,
  trap,
  versionId,
  map,
  fieldOptions,
  faults,
  lifecycle,
  ownsNamespace
)
  return setmetatable({
    runtime = runtime,
    saveNamespace = namespace,
    removeSaveNamespace = harness.removeSaveNamespace,
    trap = trap,
    timeline = {},
    hosts = runtime.scriptHosts or {},
    lifecycle = lifecycle,
    worldProbe = { flags = {}, variables = {} },
    faults = faults,
    harness = harness,
    map = map,
    fieldOptions = fieldOptions,
    versionId = versionId,
    saveStatus = runtime.saveStatus,
    ownsNamespace = ownsNamespace,
  }, Game)
end

function Game:_disposeRuntime()
  if self.runtimeDisposed then
    return
  end
  self.runtimeDisposed = true
  local runtime = self.runtime
  if not runtime then
    return
  end
  self.lifecycle.runtimeDisposals = self.lifecycle.runtimeDisposals + 1
  local ok, err = pcall(function()
    runtime:dispose()
  end)
  self.saveStatus = runtime.saveStatus or self.saveStatus
  if not ok then
    self.disposeErr = err
  end
end

function Game:restart(options)
  options = options or {}
  local save = options.save or "resume"
  assert(save == "fresh" or save == "resume", "acceptance restart save must be fresh or resume")
  self:_disposeRuntime()
  if self.disposeErr then
    error(self.disposeErr, 0)
  end
  local previousSaveStatus = self.saveStatus
  local ok, runtime = pcall(
    self.harness._newRuntime,
    self.harness,
    self.versionId,
    options.map or self.map,
    self.saveNamespace,
    save,
    self.faults,
    self.lifecycle,
    self.fieldOptions
  )
  if not ok then
    error(runtime, 0)
  end
  assert(
    runtime and runtime.session,
    "acceptance restart runtime boot failed: " .. tostring(runtime and runtime.errorText)
  )
  self.runtime = runtime
  self.map = options.map or self.map
  self.hosts = runtime.scriptHosts or {}
  self.runtimeDisposed = false
  self.disposeErr = nil
  self.saveStatus = previousSaveStatus and previousSaveStatus:find("Save failed:", 1, true) and previousSaveStatus
    or runtime.saveStatus
  return self
end

function Game:snapshot()
  local runtime = self.runtime
  local player = runtime.player or {}
  local dialogue = runtime.dialogue
  local scheduler = runtime.scripts and runtime.scripts.scheduler
  local actors, occupancy = {}, {}
  if runtime.actors and runtime.runtimeMap then
    for _, actor in ipairs(runtime.actors:actorsOf(runtime.runtimeMap.mapId)) do
      actors[actor.actorId] = {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        surfaceId = actor.surfaceId,
        facing = actor.facing,
      }
      if actor.solid then
        occupancy[actor.fieldX .. ":" .. actor.fieldZ] = actor.actorId
      end
    end
  end
  return {
    versionId = runtime.versionId,
    mapId = runtime.runtimeMap and runtime.runtimeMap.mapId,
    mapSymbol = runtime.runtimeMap and runtime.runtimeMap.mapSymbol,
    tick = runtime.session and runtime.session.tick,
    player = {
      fieldX = player.fieldX,
      fieldZ = player.fieldZ,
      worldY = player.worldY,
      surfaceId = player.surfaceId,
      facing = player.facing,
      motion = player.motion,
    },
    dialogue = dialogue and dialogue:status() or { modal = false },
    menu = runtime.menuHost and runtime.menuHost:snapshot() or nil,
    fieldLocked = scheduler and scheduler:playerMovementLocked() or false,
    transition = { phase = runtime.transition and runtime.transition.phase },
    avatarId = runtime.avatar and runtime.avatar.id,
    world = self.worldProbe,
    actors = actors,
    occupancy = occupancy,
  }
end

function Game:actor(actorId)
  assert(type(actorId) == "string", "acceptance actor id required")
  return self:snapshot().actors[actorId]
end

function Game:setWorldState(change)
  assert(type(change) == "table", "acceptance world-state change required")
  local world = assert(self.runtime.scripts and self.runtime.scripts.worldState, "field world state unavailable")
  if change.flag ~= nil then
    world:setFlag(change.flag)
    self.worldProbe.flags[change.flag] = true
  end
  if change.value ~= nil then
    assert(change.variable ~= nil, "acceptance world-state value requires a variable id")
    world:setVar(change.variable, change.value)
    self.worldProbe.variables[change.variable] = change.value
  end
end

function Game:setActorRemovalFlag(actorId)
  assert(type(actorId) == "string", "acceptance actor id required")
  local actor = assert(self.runtime.actors:getById(actorId), "actor is not visible: " .. actorId)
  local eventFlag = assert(actor.sourceEvent.eventFlag, "actor has no removal flag")
  assert(eventFlag ~= 0, "actor has no removal flag")
  self.runtime.eventState:setFlag(eventFlag)
end

function Game:failNextSave()
  self.faults.failWrite = true
end

local function interactionFor(runtime)
  local player = runtime.player
  if not player or not runtime.interactionResolver then
    return nil
  end
  return runtime.interactionResolver:resolve({
    runtimeMap = runtime.runtimeMap,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    surfaceId = player.surfaceId,
    worldY = player.worldY,
    facing = player.facing,
    tick = runtime.session and runtime.session.tick + 1 or 0,
  })
end

function Game:interaction()
  local interaction = self.lastInteraction or {}
  local actor = interaction.actorId and self.runtime.actors:getById(interaction.actorId) or nil
  return {
    kind = interaction.kind,
    actorId = interaction.actorId,
    scriptId = interaction.scriptId,
    scriptSource = interaction.scriptSource,
    actorFacing = actor and actor.facing or nil,
    actorFacingOverride = actor and actor.interactionFacingOverride or nil,
  }
end

function Game:pressAction()
  local runtime = self.runtime
  local intent = interactionFor(runtime)
  local interaction = { kind = intent and intent.kind }
  if intent and intent.object then
    interaction.actorId = intent.object.actorId
  end
  local hit = intent and runtime.scripts.client:resolve(intent) or nil
  if hit then
    interaction.scriptId = hit.trigger.scriptId
    interaction.scriptSource = "vanilla"
    for _, entry in ipairs(hit.composed.entries) do
      if entry.operation == "override" or (entry.script.metadata and entry.script.metadata.override) then
        interaction.scriptSource = "override"
      end
    end
  end
  self.lastInteraction = interaction
  runtime:pressAction()
  self:step()
  runtime:releaseAction()
  return self:snapshot()
end

function Game:advanceDialogue()
  local confirmed = false
  for _ = 1, 480 do
    local snapshot = self:snapshot()
    if not snapshot.dialogue.modal and not snapshot.fieldLocked then
      break
    end
    self.runtime:pressAction()
    self:step()
    self.runtime:releaseAction()
    confirmed = true
  end
  local final = self:snapshot()
  assert(not final.dialogue.modal and not final.fieldLocked, "dialogue did not close after semantic confirm edges")
  return { confirmed = confirmed, snapshot = self:snapshot() }
end

function Game:hostEffects()
  return self.hosts.effects
end

-- Start a real ROM-derived script through the production FieldScripts
-- composition and scheduler. Acceptance uses this only for scripts without a
-- map binding; it never supplies a synthetic graph or substitutes services.
function Game:startScript(scriptId)
  assert(type(scriptId) == "string", "acceptance script id required")
  local scripts = assert(self.runtime.scripts, "field scripts unavailable")
  local composed = assert(scripts.composition:effective(scriptId), "generated script is unavailable: " .. scriptId)
  local instanceId = scripts.scheduler:startInteraction(
    { kind = "acceptance", scriptId = scriptId },
    composed,
    assert(self.runtime.session, "field session unavailable").tick
  )
  assert(instanceId, "foreground script already owns the field")
  self:_record()
  return self:snapshot()
end

-- The runtime owns this logical status even when its presentation option is
-- false, which is the non-rendering acceptance composition.
function Game:auxiliaryUiStatus()
  local auxiliary = assert(self.runtime.auxiliaryFieldUi, "field runtime does not expose auxiliary field UI")
  return auxiliary:status()
end

-- Context choices are a distinct script-owned flow. This narrow test adapter
-- observes the production provider without constructing a menu or script host.
function Game:contextChoiceStatus()
  local provider = self.runtime.contextChoiceProvider
  return provider and provider:status() or nil
end

function Game:failForegroundScript(scriptId)
  assert(type(scriptId) == "string", "foreground script id required")
  local runtime = self.runtime
  if scriptId == "elms_lab.elm" then
    self:moveTo({ fieldX = 6, fieldZ = 6 })
    self:face("north")
  end
  self:pressAction()
  assert(self.lastInteraction.scriptId == scriptId, "foreground script does not match interaction")
  local scheduler = runtime.scripts.scheduler
  local environmentId = assert(scheduler:foregroundEnvironmentId(), "foreground script did not start")
  scheduler:cancelEnvironment(environmentId, "acceptance injected failure for " .. scriptId)
  return { error = "acceptance injected failure for " .. scriptId }
end

function Game:_record()
  local snapshot = self:snapshot()
  if self.lastSnapshot and self.lastSnapshot.mapId ~= snapshot.mapId then
    self.lastTransition = { source = self.lastSnapshot, destination = snapshot }
  end
  self.lastSnapshot = snapshot
  self.timeline[#self.timeline + 1] = snapshot
  if #self.timeline > TRACE_LIMIT then
    table.remove(self.timeline, 1)
  end
end

function Game:trace()
  return self.timeline
end

function Game:step(input)
  if input and input.direction then
    self.runtime:press(input.direction)
  end
  self.runtime:update((self.runtime.session and self.runtime.session.FIXED_DT) or (1 / 30))
  if input and input.direction then
    self.runtime:release(input.direction)
  end
  self:_record()
  return self:snapshot()
end

function Game:move(direction)
  self.runtime:press(direction)
  self:step()
  self.runtime:release(direction)
end

function Game:_moveOne(direction)
  local before = self:snapshot()
  self:move(direction)
  return self:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
      and (
        snapshot.player.fieldX ~= before.player.fieldX
        or snapshot.player.fieldZ ~= before.player.fieldZ
        or snapshot.player.facing == direction
      )
  end, 120)
end

function Game:moveTo(target)
  assert(type(target) == "table", "movement target required")
  assert(type(target.fieldX) == "number" and type(target.fieldZ) == "number", "integer field target required")
  local player = assert(self.runtime.player, "acceptance runtime player required")
  local targetKey = target.fieldX .. ":" .. target.fieldZ
  local function copyPlayer(source)
    local copy = {}
    for key, value in pairs(source) do
      copy[key] = value
    end
    return setmetatable(copy, getmetatable(source))
  end
  local queue = { { player = copyPlayer(player), route = {} } }
  local seen = { [player.fieldX .. ":" .. player.fieldZ] = true }
  local route
  local head = 1
  local directions = { "north", "south", "west", "east" }
  while queue[head] do
    local node = queue[head]
    head = head + 1
    if node.player.fieldX .. ":" .. node.player.fieldZ == targetKey then
      route = node.route
      break
    end
    for _, direction in ipairs(directions) do
      local destination = node.player:_resolveStep(direction)
      if destination then
        local key = destination.fieldX .. ":" .. destination.fieldZ
        local isWarp = false
        for _, warp in ipairs(node.player.currentMap.fieldData.events.warps) do
          if warp.x == destination.fieldX and warp.z == destination.fieldZ then
            isWarp = true
            break
          end
        end
        if not seen[key] and (not isWarp or key == targetKey) then
          seen[key] = true
          local nextRoute = {}
          for index, step in ipairs(node.route) do
            nextRoute[index] = step
          end
          nextRoute[#nextRoute + 1] = direction
          local nextPlayer = copyPlayer(node.player)
          for key, value in pairs(destination) do
            nextPlayer[key] = value
          end
          queue[#queue + 1] = { player = nextPlayer, route = nextRoute }
        end
      end
    end
  end
  assert(route, "no production movement route to " .. targetKey)
  for _, direction in ipairs(route) do
    self:_moveOne(direction)
  end
  return self:snapshot()
end

function Game:moveUntilBlocked(direction)
  local before = self:snapshot()
  self:_moveOne(direction)
  local after = self:snapshot()
  assert(
    after.player.fieldX == before.player.fieldX and after.player.fieldZ == before.player.fieldZ,
    "expected production movement to be blocked"
  )
  return after
end

function Game:face(direction)
  self:advanceUntil("prior movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  self:_moveOne(direction)
  return self:snapshot()
end

function Game:waitForTransition()
  if self.lastTransition then
    local completed = self.lastTransition
    self.lastTransition = nil
    return completed
  end
  local source = self:snapshot()
  self:advanceUntil("transition completes", function(snapshot)
    return snapshot.mapId ~= source.mapId and snapshot.transition.phase == "idle"
  end, 120)
  local destination = self:snapshot()
  self.lastTransition = nil
  return { source = source, destination = destination }
end

function Game:ownership()
  local runtime = self.runtime
  local mapProtections = 0
  for _ in pairs(runtime.mapLoader.protectedMaps) do
    mapProtections = mapProtections + 1
  end
  local activeActorMaps = 0
  for _ in pairs(runtime.actors.maps) do
    activeActorMaps = activeActorMaps + 1
  end
  return {
    mapProtections = mapProtections,
    activeActorMaps = activeActorMaps,
    sessionReferences = runtime.session and 1 or 0,
  }
end

function Game:advanceUntil(label, predicate, maxTicks)
  assert(type(label) == "string" and label ~= "", "advanceUntil label required")
  assert(type(predicate) == "function", "advanceUntil predicate required")
  assert(
    type(maxTicks) == "number" and maxTicks >= 0 and maxTicks < math.huge and maxTicks == math.floor(maxTicks),
    "advanceUntil maxTicks must be a finite non-negative integer"
  )
  for _ = 0, maxTicks do
    local snapshot = self:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    if _ < maxTicks then
      self:step()
    end
  end
  error(
    "timed out waiting for "
      .. label
      .. "; trace="
      .. tostring(#self.timeline)
      .. " snapshots; last tick="
      .. tostring(self:snapshot().tick),
    2
  )
end

function Game:renderAttempts()
  return self.trap.attempts
end

function Game:replay(inputs, options)
  assert(type(inputs) == "table", "acceptance replay inputs required")
  options = options or {}
  local replay = self.harness:boot({
    versionId = self.versionId,
    map = options.map or self.map,
    save = options.save or "fresh",
  })
  local ok, result = xpcall(function()
    for _, input in ipairs(inputs) do
      if input == "action" then
        replay:pressAction()
      else
        replay:move(input)
      end
    end
    return { trace = replay:trace() }
  end, debug.traceback)
  replay:close()
  if not ok then
    error(result, 0)
  end
  return result
end

function Game:replaceApplicationState()
  local replaced = self
  local previousState = {
    dispose = function()
      replaced:_disposeRuntime()
    end,
  }
  local activeState = {}
  App.setState(previousState)
  App.setState(activeState)
  if replaced.disposeErr then
    error(replaced.disposeErr, 0)
  end

  local activeLifecycle = { saveWrites = 0, runtimeDisposals = 0 }
  local ok, runtime = pcall(
    self.harness._newRuntime,
    self.harness,
    self.versionId,
    self.map,
    self.saveNamespace,
    "resume",
    self.faults,
    activeLifecycle
  )
  if not ok then
    App.setState(nil)
    error(runtime, 0)
  end
  assert(
    runtime and runtime.session,
    "acceptance replacement runtime boot failed: " .. tostring(runtime and runtime.errorText)
  )
  local active = gameFor(
    self.harness,
    runtime,
    self.saveNamespace,
    self.trap,
    self.versionId,
    self.map,
    self.fieldOptions,
    self.faults,
    activeLifecycle,
    false
  )
  activeState.dispose = function()
    active:_disposeRuntime()
  end
  App.quit()
  if active.disposeErr then
    error(active.disposeErr, 0)
  end
  return {
    replaced = { lifecycle = replaced.lifecycle, saveStatus = replaced.saveStatus },
    active = { lifecycle = active.lifecycle, saveStatus = active.saveStatus },
  }
end

function Game:close()
  if self.closed then
    return
  end
  self:_disposeRuntime()
  self.trap:restore()
  if self.ownsNamespace then
    self.removeSaveNamespace(self.saveNamespace)
  end
  self.closed = true
  if self.disposeErr then
    error(self.disposeErr, 0)
  end
end

---@param options table|nil
---@return AcceptanceHarness
function AcceptanceHarness.new(options)
  options = options or {}
  return setmetatable({
    versions = options.versions or readyVersions(),
    runtimeFactory = options.runtimeFactory or function(versionId, map, runtimeOptions)
      return FieldRuntime.new(versionId, map, runtimeOptions)
    end,
    saveNamespace = options.saveNamespace or defaultNamespace,
    removeSaveNamespace = options.removeSaveNamespace or removeNamespace,
  }, AcceptanceHarness)
end

function AcceptanceHarness:forEachVersion(fn)
  for _, versionId in ipairs(self.versions) do
    fn(versionId)
  end
end

---@return AcceptanceGame
function AcceptanceHarness:boot(options)
  assert(options and type(options.versionId) == "string", "acceptance boot version required")
  serial = serial + 1
  local namespace = self.saveNamespace(options.versionId, serial)
  local trap = installRenderTrap()
  local faults = {}
  local lifecycle = { saveWrites = 0, runtimeDisposals = 0 }
  local ok, runtime = pcall(
    self._newRuntime,
    self,
    options.versionId,
    options.map,
    namespace,
    options.save,
    faults,
    lifecycle,
    options.fieldOptions
  )
  if not ok then
    abortBoot(nil, trap, self.removeSaveNamespace, namespace)
    error(runtime, 0)
  end
  if not runtime or not runtime.session then
    local errorText = runtime and runtime.errorText
    abortBoot(runtime, trap, self.removeSaveNamespace, namespace)
    error("acceptance runtime boot failed: " .. tostring(errorText), 0)
  end
  return gameFor(
    self,
    runtime,
    namespace,
    trap,
    options.versionId,
    options.map,
    options.fieldOptions,
    faults,
    lifecycle,
    true
  )
end

function AcceptanceHarness:bootWithCorruptArtifact(versionId, artifact)
  assert(type(versionId) == "string" and type(artifact) == "string", "version and artifact required")
  local originalFactory = self.runtimeFactory
  local disposeCount = 0
  self.runtimeFactory = function()
    return {
      errorText = "required " .. artifact .. " artifact is corrupt",
      dispose = function()
        disposeCount = disposeCount + 1
      end,
    }
  end
  local ok, err = pcall(function()
    self:boot({ versionId = versionId, save = "fresh" })
  end)
  self.runtimeFactory = originalFactory
  assert(not ok, "corrupt artifact boot must fail")
  return { error = tostring(err), disposeCount = disposeCount }
end

return AcceptanceHarness
