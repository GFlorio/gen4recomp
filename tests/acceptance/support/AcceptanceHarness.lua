-- Production-composed, non-rendering field acceptance harness. It owns an
-- isolated save namespace and a temporary graphics trap around each runtime,
-- while FieldRuntime remains the sole owner of maps, scripts, actors, and saves.

local FieldSave = require("libs.engine.src.FieldSave")
local SaveFs = require("libs.storage.src.SaveFs")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local App = require("game.src.game.App")
local RecordingScriptHosts = require("tests.acceptance.support.RecordingScriptHosts")
local AcceptanceScriptFs = require("tests.acceptance.support.AcceptanceScriptFs")
local RepoFs = require("game.src.game.RepoFs")

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

-- Acceptance owns the save-root host boundary: every SaveFs path below the
-- normal `saves/<versionId>/` root is remapped into the per-boot acceptance
-- namespace, so an acceptance run can never touch the user's real saves and
-- the production SaveFs constructor needs no test-only rooting mode. The
-- wrapper also injects one scoped write or read failure without changing the
-- runtime's real save composition.
local function saveBackend(faults, lifecycle, namespace)
  local fs = love.filesystem
  local function remap(path)
    local rest = path:gsub("^saves/[^/]+", "")
    local remapped = namespace .. "/" .. rest:gsub("^/", "")
    return (remapped:gsub("/$", ""))
  end
  return {
    write = function(_, path, data)
      lifecycle.saveWrites = lifecycle.saveWrites + 1
      if faults.failWrite then
        faults.failWrite = false
        return false, "acceptance injected save write failure"
      end
      return fs.write(remap(path), data)
    end,
    read = function(_, path)
      lifecycle.saveReads = lifecycle.saveReads + 1
      if faults.failRead then
        faults.failRead = false
        return nil, "acceptance injected save read failure"
      end
      return fs.read(remap(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(remap(path))
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(remap(path))
    end,
    remove = function(_, path)
      return fs.remove(remap(path))
    end,
    replace = function(_, sourcePath, destinationPath)
      return os.rename(
        fs.getSaveDirectory() .. "/" .. remap(sourcePath),
        fs.getSaveDirectory() .. "/" .. remap(destinationPath)
      )
    end,
  }
end

-- The render trap wraps process-global graphics functions, so it cannot be
-- owned per game: a second boot while a first game is live would capture the
-- first game's trapped functions as its "originals", and closing in the wrong
-- order would leave the namespace trapped forever. The real functions are
-- therefore captured once per process and restored by the first close; any
-- boot/close sequence leaves the namespace untrapped.
local TRAPPED_FUNCTIONS = { "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw" }
local graphicsOriginals = nil

local function installRenderTrap()
  local graphics = love and love.graphics
  if not graphics then
    return { attempts = 0, restore = function() end }
  end
  if graphicsOriginals == nil then
    graphicsOriginals = {}
    for _, name in ipairs(TRAPPED_FUNCTIONS) do
      graphicsOriginals[name] = graphics[name]
    end
  end
  local trap = { attempts = 0 }
  for _, name in ipairs(TRAPPED_FUNCTIONS) do
    graphics[name] = function()
      trap.attempts = trap.attempts + 1
      error("acceptance runtime attempted love.graphics." .. name, 2)
    end
  end
  function trap:restore()
    if graphicsOriginals == nil then
      return
    end
    for name, value in pairs(graphicsOriginals) do
      graphics[name] = value
    end
    graphicsOriginals = nil
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
---@field lifecycle { saveWrites: integer, saveReads: integer, runtimeDisposals: integer }
---@field worldProbe { flags: table<integer, boolean>, variables: table<integer, integer> }
---@field faults { failWrite: boolean?, failRead: boolean? }
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
  runtimeOptions.saveFs = SaveFs.forVersion(versionId, saveBackend(faults, lifecycle, namespace))
  runtimeOptions.resumeSave = save == "resume"
  runtimeOptions.resetSave = save == "fresh"
  -- Recording script hosts are an explicit test composition. `audioHost =
  -- "production"` still omits only the recording audio adapter so the field-
  -- audio acceptance scenarios can observe the real GameSound composition.
  if fieldOptions and fieldOptions.recordingScriptHosts == true then
    runtimeOptions.scriptHosts = RecordingScriptHosts.new({ audio = fieldOptions.audioHost ~= "production" })
  end
  if fieldOptions and fieldOptions.acceptanceScripts then
    runtimeOptions.overrideFs =
      AcceptanceScriptFs.new(RepoFs.new(love.filesystem.getSourceBaseDirectory()), fieldOptions.acceptanceScripts)
  end
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
  ---@cast runtime FieldRuntime
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
  local camera = runtime.camera
  local dialogue = runtime.dialogue
  local scheduler = runtime.scripts and runtime.scripts.scheduler
  local actors, occupancy = {}, {}
  if runtime.actors and runtime.runtimeMap then
    local runtimeActors = runtime.actors
    ---@cast runtimeActors FieldActorManager
    for _, actor in ipairs(FieldActorManager.actorsOf(runtimeActors, runtime.runtimeMap.mapId)) do
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
  local appHostStatus = runtime.applicationHost and runtime.applicationHost:status() or {}
  return {
    versionId = runtime.versionId,
    mapId = runtime.runtimeMap and runtime.runtimeMap.mapId,
    mapSymbol = runtime.runtimeMap and runtime.runtimeMap.mapSymbol,
    tick = runtime.session and runtime.session.tick,
    player = {
      fieldX = player.fieldX,
      fieldZ = player.fieldZ,
      localX = player.localX,
      localZ = player.localZ,
      worldX = player.worldX,
      worldY = player.worldY,
      worldZ = player.worldZ,
      previousWorldX = player.previousWorldX,
      previousWorldY = player.previousWorldY,
      previousWorldZ = player.previousWorldZ,
      surfaceId = player.surfaceId,
      facing = player.facing,
      motion = player.motion,
    },
    camera = camera and {
      sourceTarget = {
        x = camera.sourceTarget.x,
        y = camera.sourceTarget.y,
        z = camera.sourceTarget.z,
      },
      target = { x = camera.target.x, y = camera.target.y, z = camera.target.z },
      previousTarget = { x = camera.previousTarget.x, y = camera.previousTarget.y, z = camera.previousTarget.z },
      eye = { x = camera.eye.x, y = camera.eye.y, z = camera.eye.z },
      previousEye = { x = camera.previousEye.x, y = camera.previousEye.y, z = camera.previousEye.z },
    } or nil,
    playerVisual = runtime.playerVisual and {
      pose = runtime.playerVisual.pose,
      poseTick = runtime.playerVisual.poseTick,
    } or nil,
    dialogue = dialogue and dialogue:status() or { modal = false },
    menu = appHostStatus.menu or (runtime.menuHost and runtime.menuHost:snapshot()) or nil,
    fieldLocked = scheduler and scheduler:playerMovementLocked() or false,
    transition = { phase = runtime.transition and runtime.transition.phase },
    avatarId = runtime.avatar and runtime.avatar.id,
    coverage = runtime.runtimeMap and runtime.runtimeMap.coverage and runtime.runtimeMap.coverage:status() or nil,
    zoneChange = runtime.lastZoneChange and {
      oldMapId = runtime.lastZoneChange.oldMapId,
      newMapId = runtime.lastZoneChange.newMapId,
      mapSectionChanged = runtime.lastZoneChange.mapSectionChanged,
    } or nil,
    terrainEffects = runtime.fieldTerrainEffectController and runtime.fieldTerrainEffectController:status() or nil,
    world = self.worldProbe,
    actors = actors,
    occupancy = occupancy,
  }
end

function Game:save()
  self.runtime:saveSession("Acceptance corridor checkpoint saved")
  return self:snapshot()
end

function Game:warpDestination(warpIndex)
  assert(type(warpIndex) == "number", "acceptance warp index required")
  local warps = assert(self.runtime.runtimeMap.fieldData.events.warps, "production warp data is required")
  local warp = assert(warps[warpIndex + 1], "acceptance warp index is unavailable")
  return {
    fieldX = warp.x or warp.fieldX,
    fieldZ = warp.z or warp.fieldZ,
    mapId = warp.destinationMapId,
    warpId = warp.destinationWarpId,
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

function Game:failNextRead()
  self.faults.failRead = true
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
  assert(
    self.hosts.effects,
    "recording hosts are disabled; boot with fieldOptions.recordingScriptHosts = true to inspect host effects"
  )
  return self.hosts.effects
end

function Game:hostEvents()
  assert(
    self.hosts.events,
    "recording hosts are disabled; boot with fieldOptions.recordingScriptHosts = true to inspect host events"
  )
  return self.hosts.events
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

function Game:moveTo(target, stopMapId)
  assert(type(target) == "table", "movement target required")
  assert(type(target.fieldX) == "number" and type(target.fieldZ) == "number", "integer field target required")
  local player = assert(self.runtime.player, "acceptance runtime player required")
  local targetKey = target.fieldX .. ":" .. target.fieldZ
  local function copyPlayer(source)
    local copy = {}
    for key, value in pairs(source) do
      copy[key] = value
    end
    -- Route search advances cloned players without publishing runtime state.
    -- The live callback would preflight arbitrary logical maps using the real
    -- player's coverage, so scope simulated occupancy to the cloned map's
    -- resident actor index instead.
    local actorManager = self.runtime.actors
    if actorManager then
      local map = assert(source.currentMap, "acceptance player map required")
      copy.occupancy = function(candidate)
        local actor = actorManager:getAt(map.mapId, candidate)
        return actor and actor.actorId or nil
      end
    end
    return setmetatable(copy, getmetatable(source))
  end
  local directions = { "north", "south", "west", "east" }
  local function buildRoute(node)
    local reversed = {}
    while node.parent do
      reversed[#reversed + 1] = {
        direction = node.direction,
        fieldX = node.player.fieldX,
        fieldZ = node.player.fieldZ,
      }
      node = node.parent
    end
    local route = {}
    for index = #reversed, 1, -1 do
      route[#route + 1] = reversed[index]
    end
    return route
  end

  local function estimateRemaining(source)
    return math.abs(source.fieldX - target.fieldX) + math.abs(source.fieldZ - target.fieldZ)
  end

  local function before(first, second)
    if first.f < second.f then
      return true
    elseif first.f > second.f then
      return false
    end
    if first.h < second.h then
      return true
    elseif first.h > second.h then
      return false
    end
    return first.sequence < second.sequence
  end

  local function push(open, node)
    open[#open + 1] = node
    local index = #open
    while index > 1 do
      local parent = math.floor(index / 2)
      if before(open[parent], open[index]) then
        break
      end
      open[parent], open[index] = open[index], open[parent]
      index = parent
    end
  end

  local function pop(open)
    local result = open[1]
    local last = table.remove(open)
    if #open > 0 then
      open[1] = last
      local index = 1
      while true do
        local left = index * 2
        local right = left + 1
        local smallest = index
        if left <= #open and before(open[left], open[smallest]) then
          smallest = left
        end
        if right <= #open and before(open[right], open[smallest]) then
          smallest = right
        end
        if smallest == index then
          break
        end
        open[index], open[smallest] = open[smallest], open[index]
        index = smallest
      end
    end
    return result
  end

  local function findRoute(source)
    local sequence = 0
    local open = {}
    local bestCost = { [source.fieldX .. ":" .. source.fieldZ] = 0 }
    local first = { player = copyPlayer(source), g = 0, h = estimateRemaining(source) }
    first.f = first.g + first.h
    sequence = sequence + 1
    first.sequence = sequence
    push(open, first)
    while #open > 0 do
      local node = pop(open)
      if node.player.fieldX .. ":" .. node.player.fieldZ == targetKey then
        return buildRoute(node)
      end
      for _, direction in ipairs(directions) do
        local nextPlayer = copyPlayer(node.player)
        if nextPlayer:tryStep(direction) then
          local duration = nextPlayer.motion == "jumping" and 16 or 8
          for _ = 1, duration do
            nextPlayer:updateFixed({})
          end
          local key = nextPlayer.fieldX .. ":" .. nextPlayer.fieldZ
          local isWarp = false
          for _, warp in ipairs(node.player.currentMap.fieldData.events.warps) do
            if warp.x == nextPlayer.fieldX and warp.z == nextPlayer.fieldZ then
              isWarp = true
              break
            end
          end
          local cost = node.g + 1
          if (not isWarp or key == targetKey) and (bestCost[key] == nil or cost < bestCost[key]) then
            bestCost[key] = cost
            local h = estimateRemaining(nextPlayer)
            sequence = sequence + 1
            push(open, {
              player = nextPlayer,
              parent = node,
              direction = direction,
              g = cost,
              h = h,
              f = cost + h,
              sequence = sequence,
            })
          end
        end
      end
    end
    return nil
  end

  local route
  local routeIndex = 1
  for _ = 1, 256 do
    player = assert(self.runtime.player, "acceptance runtime player required")
    if player.fieldX .. ":" .. player.fieldZ == targetKey then
      return self:snapshot()
    end
    if not route or routeIndex > #route then
      route = assert(findRoute(player), "no production movement route to " .. targetKey)
      routeIndex = 1
    end
    local step = assert(route[routeIndex], "production movement route made no progress")
    local sourceMapId = player.currentMap and player.currentMap.mapId
    local snapshot = self:_moveOne(step.direction)
    if
      snapshot.mapId == sourceMapId
      and snapshot.player.fieldX == step.fieldX
      and snapshot.player.fieldZ == step.fieldZ
    then
      routeIndex = routeIndex + 1
    else
      route = nil
    end
    if stopMapId ~= nil and snapshot.mapId == stopMapId then
      return snapshot
    end
  end
  error("production movement route exceeded 256 steps to " .. targetKey)
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
  if
    self.lastTransition
    and self.lastTransition.destination.transition.phase == "idle"
    and not self.lastTransition.destination.fieldLocked
  then
    local completed = self.lastTransition
    self.lastTransition = nil
    return completed
  end
  local source = self.lastTransition and self.lastTransition.source or self:snapshot()
  self:advanceUntil("transition completes", function(snapshot)
    return snapshot.mapId ~= source.mapId and snapshot.transition.phase == "idle" and not snapshot.fieldLocked
  end, 120)
  local completed = assert(self.lastTransition, "completed transition snapshot missing")
  self.lastTransition = nil
  return { source = completed.source, destination = self:snapshot() }
end

function Game:ownership()
  local runtime = self.runtime
  local mapProtections = 0
  local mapProtectedIds = {}
  for mapId in pairs(runtime.mapLoader.protectedMaps) do
    mapProtections = mapProtections + 1
    mapProtectedIds[#mapProtectedIds + 1] = mapId
  end
  table.sort(mapProtectedIds)
  local activeActorMaps = 0
  for _ in pairs(runtime.actors.maps) do
    activeActorMaps = activeActorMaps + 1
  end
  return {
    mapProtections = mapProtections,
    mapProtectedIds = mapProtectedIds,
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
      .. "; "
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

  local activeLifecycle = { saveWrites = 0, saveReads = 0, runtimeDisposals = 0 }
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

---@return string
function AcceptanceHarness.defaultVersion()
  local versions = readyVersions()
  assert(#versions > 0, "acceptance harness requires a ready game version")
  return versions[1]
end

---@return string
function AcceptanceHarness:primaryVersion()
  assert(#self.versions > 0, "acceptance harness requires at least one selected version")
  return self.versions[1]
end

function AcceptanceHarness:forEachVersion(fn)
  for _, versionId in ipairs(self.versions) do
    fn(versionId)
  end
end

---@param options table
---@return AcceptanceGame
function AcceptanceHarness:boot(options)
  assert(options and type(options.versionId) == "string", "acceptance boot version required")
  serial = serial + 1
  local namespace = self.saveNamespace(options.versionId, serial)
  local trap = installRenderTrap()
  local faults = {}
  local lifecycle = { saveWrites = 0, saveReads = 0, runtimeDisposals = 0 }
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
    error("acceptance runtime boot failed: " .. tostring(runtime), 0)
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
