-- Runs the authoritative field simulation at 30 fixed ticks per second, the
-- DS field cadence (the fixed-step accumulator is render-delta independent).
-- Player movement advances before the camera so both consume the same
-- continuous XYZ. A modal dialogue owns the tick: once the fade/transition
-- phase (which cannot be active while a dialogue is open) has advanced, the
-- session steps the dialogue, advances the scene animation clock, and
-- returns, so movement, warps, interactions, actor pose clocks, and the
-- camera freeze until the dialogue closes.
-- Variable-delta `update(dt)` obtains a fresh input snapshot for every fixed
-- step it executes, so an edge can never be replayed across catch-up ticks;
-- `updateFixed(snapshot)` is the explicit deterministic unit-test API.
--
-- Step 6 is wired through the `interactions`
-- service: `resolve(snapshot)` returns an immutable InteractionIntent for an
-- idle player's Action edge, which the session dispatches to
-- `scriptClient:consume(intent, tick)`. A consumed interaction owns the
-- tick, so the same edge can never also start a move or a warp. There is no
-- fallback client: the load-time binding audit guarantees bindings for every
-- runtime map represented by the generated binding manifest.
-- The resolve service is invoked with the interactions table as self (colon
-- style), so implementations must declare a leading self parameter.
--
-- The session owns no 60 Hz audio timing: its audio collaborator receives
-- field-policy updates at semantic boundaries and semantic effects from field
-- traversal. The 60 Hz sound-frame clock is the runtime's wall-clock accumulator.

local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local WarpSystem = require("libs.engine.src.WarpSystem")
local ScriptInteractionClient = require("libs.engine.src.script.ScriptInteractionClient")
local FieldTransition = require("libs.engine.src.FieldTransition")

---@class FieldSessionOptions
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field player FieldPlayer
---@field camera FieldCamera
---@field transition FieldTransition
---@field actors FieldActorManager
---@field playerVisual FieldPlayerVisual?
---@field dialogue FieldDialogueController
---@field input FieldInput
---@field interactions FieldSession.Interactions
---@field eventResolver table
---@field eventState FieldEventState
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field signpost FieldSignpostController
---@field applicationHost FieldApplicationHost the one application modal owner (Start Menu and its destinations)
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field terrainEffects FieldTerrainEffectController?
---@field audio { updateField: fun(self: table), play: fun(self: table, idOrSymbol: string) }?
---@field navigationBoundary table?

---@class FieldSession.Interactions
---@field resolve fun(self: FieldSession.Interactions, snapshot: InteractionResolverSnapshot): InteractionIntent?

---@class FieldSession
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field player FieldPlayer
---@field camera FieldCamera
---@field transition FieldTransition
---@field actors FieldActorManager
---@field playerVisual FieldPlayerVisual?
---@field dialogue FieldDialogueController
---@field input FieldInput
---@field interactions FieldSession.Interactions
---@field eventResolver table
---@field eventState FieldEventState
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field signpost FieldSignpostController the fixed-tick signpost controller (save-gate interrogation only; the scheduler steps it)
---@field applicationHost FieldApplicationHost the one application modal owner (Start Menu and its destinations)
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field terrainEffects FieldTerrainEffectController?
---@field audio { updateField: fun(self: table), play: fun(self: table, idOrSymbol: string) }?
---@field tick integer
---@field accumulator number
---@field navigationBoundary table?
---@field _boundaryMovementDirection FieldDirection?
local FieldSession = {}
FieldSession.__index = FieldSession

-- The DS field cadence: 30 fixed ticks per second, owned here.
FieldSession.FIXED_HZ = 30
FieldSession.FIXED_DT = 1 / FieldSession.FIXED_HZ
FieldSession.MAX_CATCH_UP_TICKS = 5

-- Float slack so a render delta that lands exactly on a tick boundary does
-- not leave a stale full tick in the accumulator.
local ACCUMULATOR_EPSILON = 1e-12

---@param options FieldSessionOptions
---@return FieldSession
-- Every collaborator the session steps on a tick is required here: the
-- production runtime supplies them unconditionally, so a session missing any
-- of them -- or missing an operation a tick path calls unconditionally -- is
-- a composition fault rather than a partial-tick configuration.
function FieldSession.new(options)
  assert(options and options.versionId and options.currentMap, "field session identity required")
  assert(
    options.currentMap and type(options.currentMap.updateAnimated) == "function",
    "field session current map animation clock required"
  )
  assert(
    options.player
      and type(options.player.updateFixed) == "function"
      and type(options.player.collapseRenderInterpolation) == "function"
      and options.camera
      and type(options.camera.updateFixed) == "function"
      and type(options.camera.collapseRenderInterpolation) == "function",
    "field session player and camera interpolation contract required"
  )
  assert(
    options.transition and options.transition.updateFixed and options.transition.start,
    "field session transition required"
  )
  assert(options.actors and options.actors.step, "field session actors required")
  assert(options.input and options.input.snapshot, "field session input required")
  assert(options.dialogue and options.dialogue.isModal, "field session dialogue required")
  assert(
    options.scriptScheduler and options.scriptScheduler.step and options.scriptScheduler.playerMovementLocked,
    "field session script scheduler required"
  )
  assert(options.scriptClient and options.scriptClient.consume, "field session script client required")
  assert(options.menuHost and options.menuHost.isModal and options.menuHost.advance, "field session menu host required")
  assert(options.contextChoice and options.contextChoice.isActive, "field session context choice required")
  assert(options.signpost and options.signpost.isModal, "field session signpost controller required")
  assert(
    options.applicationHost
      and options.applicationHost.isActive
      and options.applicationHost.updateFixed
      and options.applicationHost.requestOpen
      and options.applicationHost.takeReopen,
    "field session application host required"
  )
  assert(options.interactions and options.interactions.resolve, "field session interaction resolver required")
  assert(
    options.fieldEntranceIndicator and options.fieldEntranceIndicator.updateFixed,
    "field entrance indicator required"
  )
  assert(
    options.eventResolver and options.eventResolver.resolveCoordinate and options.eventResolver.resolvePassiveSign,
    "field event resolver required"
  )
  assert(options.eventState and options.eventState.getVar, "field event state required")
  if options.audio then
    assert(
      type(options.audio.updateField) == "function" and type(options.audio.play) == "function",
      "field session audio field-policy update and effect playback required"
    )
  end
  return setmetatable({
    versionId = options.versionId,
    currentMap = options.currentMap,
    player = options.player,
    camera = options.camera,
    transition = options.transition,
    actors = options.actors,
    playerVisual = options.playerVisual,
    dialogue = options.dialogue,
    input = options.input,
    interactions = options.interactions,
    eventResolver = options.eventResolver,
    eventState = options.eventState,
    scriptScheduler = options.scriptScheduler,
    scriptClient = options.scriptClient,
    menuHost = options.menuHost,
    contextChoice = options.contextChoice,
    signpost = options.signpost,
    applicationHost = options.applicationHost,
    fieldEntranceIndicator = options.fieldEntranceIndicator,
    terrainEffects = options.terrainEffects,
    audio = options.audio,
    navigationBoundary = options.navigationBoundary,
    tick = 0,
    accumulator = 0,
    _boundaryMovementDirection = nil,
  }, FieldSession)
end

function FieldSession:actorTarget()
  return { x = self.player.worldX, y = self.player.worldY, z = self.player.worldZ }
end

-- The idle-boundary gate for the Start Menu open edge: the menu may open
-- only at a settled field boundary -- player idle, transition idle, no
-- dialogue/signpost/script menu/context choice, and no script-owned
-- movement lock. Any non-idle player motion means "not idle"; the active
-- application branch above has already returned before this code runs.
---@return boolean
local function canOpenStartMenu(self)
  return self.player.motion == "idle"
    and self.transition.phase == FieldTransition.PHASES.idle
    and not self.dialogue:isModal()
    and not self.signpost:isModal()
    and not self.menuHost:isModal()
    and not self.contextChoice:isActive()
    and not self.scriptScheduler:playerMovementLocked()
end

function FieldSession:_advanceTick()
  self.fieldEntranceIndicator:updateFixed({
    map = self.currentMap,
    player = self.player,
    transition = { ownsField = self.transition.phase == FieldTransition.PHASES.idle },
  })
  self.tick = self.tick + 1
end

function FieldSession:_emitTerrainResponse()
  if not self.terrainEffects then
    return
  end
  local origin = assert(self.currentMap.coordinateOrigin, "terrain response map origin is required")
  local localX, localZ = self.player.fieldX - origin.x, self.player.fieldZ - origin.z
  local cell = self.currentMap.collision:getLocal(localX, localZ)
  local responses = require("libs.engine.src.FieldTerrainResponse").resolve({
    committed = true,
    destination = {
      behavior = cell.behavior,
      fieldX = self.player.fieldX,
      fieldZ = self.player.fieldZ,
      worldY = self.player.worldY,
      originY = self.currentMap.physicalOrigin and self.currentMap.physicalOrigin.y or 0,
      cellKey = self.player.committedSourceCellKey,
      sourceSurfaceId = self.player.committedSourceSurfaceId,
    },
    direction = self.player.facing,
  })
  self.terrainEffects:emitAll(responses)
end

local function resolveCoordinate(self)
  local events = self.currentMap.fieldData and self.currentMap.fieldData.events
  if not events or not events.coordinates then
    return nil
  end
  return self.eventResolver.resolveCoordinate(self.currentMap, self.player, self.eventState)
end

local function resolvePassiveSign(self)
  local events = self.currentMap.fieldData and self.currentMap.fieldData.events
  if not events or not events.background then
    return nil
  end
  return self.eventResolver.resolvePassiveSign(self.currentMap, self.player)
end

local function consumeScriptIntent(self, intent)
  local result = self.scriptClient:consume(intent, self.tick + 1)
  local results = ScriptInteractionClient.RESULTS
  assert(
    result == results.started or result == results.blocked,
    "a field event must be bound: " .. tostring(intent.mapId)
  )
end

local function settleScriptHandoffPresentation(self)
  assert(self.player.motion == "idle", "script handoff requires an idle player")
  if self.playerVisual then
    self.playerVisual:settle()
  end
  self.player:collapseRenderInterpolation()
  self.camera:updateFixed(self:actorTarget())
  self.camera:collapseRenderInterpolation()
end

function FieldSession:_updateTerrainAndTransition()
  if self.terrainEffects then
    self.terrainEffects:updateFixed({
      fieldX = self.player.fieldX,
      fieldZ = self.player.fieldZ,
      facing = self.player.facing,
    })
  end
  local playerAdvanced = self.transition:updateFixed()
  if not self.transition.locked and not self.transition.completed then
    return false
  end
  if not playerAdvanced and self.player.motion == "idle" then
    self.player:collapseRenderInterpolation()
  end
  self.currentMap:updateAnimated()
  if self.playerVisual and playerAdvanced then
    self.playerVisual:updateFixed(true)
  end
  self.camera:updateFixed(self:actorTarget())
  if self.transition.completed then
    self.camera:collapseRenderInterpolation()
  end
  if self.transition.completed and self.input.clearEdges then
    self.input:clearEdges()
  end
  return true
end

function FieldSession:_updateApplication(inputSnapshot)
  if not self.applicationHost:isActive() then
    return false
  end
  assert(
    not self.dialogue:isModal() and not self.signpost:isModal() and not self.menuHost:isModal(),
    "the application host owns the tick; no other modal may be active"
  )
  local uiEvents = self.input:uiSnapshot(self.tick + 1)
  if inputSnapshot.menuPressed then
    uiEvents[#uiEvents + 1] = { type = "menu" }
  end
  self.applicationHost:updateFixed(uiEvents)
  return true
end

function FieldSession:_updateDialogue(inputSnapshot)
  if not self.dialogue:isModal() or (self.dialogue.isScriptOwned and self.dialogue:isScriptOwned()) then
    return false
  end
  self.currentMap:updateAnimated()
  self.dialogue:step(inputSnapshot)
  return true
end

function FieldSession:_updateScript(inputSnapshot)
  self.currentMap:updateAnimated()
  local movementLockedAtTickStart = self.scriptScheduler:playerMovementLocked()
  local schedulerInput = {
    heldDirection = inputSnapshot.heldDirection,
    pressedDirection = inputSnapshot.pressedDirection,
    pressedAction = inputSnapshot.actionPressed,
    pressedCancel = inputSnapshot.cancelPressed,
    actionDown = inputSnapshot.actionDown,
    cancelDown = inputSnapshot.cancelDown,
  }
  local menuModal = self.menuHost:isModal()
  local contextChoiceModal = self.contextChoice:isActive()
  if menuModal or contextChoiceModal then
    local uiEvents = self.input:uiSnapshot(self.tick + 1)
    if menuModal then
      schedulerInput.menuEvents = self.menuHost:inputEvents(uiEvents)
    else
      schedulerInput.uiEvents = uiEvents
    end
    schedulerInput.pressedDirection = nil
    schedulerInput.pressedAction = nil
    schedulerInput.pressedCancel = nil
  end
  self.scriptScheduler:step(self.tick + 1, schedulerInput)
  self.menuHost:advance(self.tick + 1)
  local contextChoiceNowModal = self.contextChoice:isActive()
  if not contextChoiceModal and contextChoiceNowModal then
    self.input:beginUi(self.tick + 1)
  elseif contextChoiceModal and not contextChoiceNowModal then
    self.input:clearUi()
  end
  if movementLockedAtTickStart or self.scriptScheduler:playerMovementLocked() then
    return true
  end
  return false
end

function FieldSession:_updateStartMenu(inputSnapshot)
  if self.applicationHost:takeReopen(self.tick + 1) then
    return true
  end
  if inputSnapshot.menuPressed and canOpenStartMenu(self) and self.applicationHost:requestOpen(self.tick + 1) then
    return true
  end
  return false
end

function FieldSession:_updateInteractionAndMovement(inputSnapshot, carriedBoundaryDirection)
  if self.transition.suppression then
    self.transition.suppression = WarpSystem.updateSuppression(
      self.transition.suppression,
      self.currentMap.mapId,
      self.player.fieldX,
      self.player.fieldZ
    )
  end
  self.actors:step(self.tick + 1)

  local passiveDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  if self.player.motion == "idle" and passiveDirection == self.player.facing then
    local intent = resolvePassiveSign(self)
    if intent then
      settleScriptHandoffPresentation(self)
      consumeScriptIntent(self, intent)
      return true
    end
  end
  if self.player.motion == "idle" and inputSnapshot.actionPressed then
    local intent = self.interactions:resolve({
      runtimeMap = self.currentMap,
      fieldX = self.player.fieldX,
      fieldZ = self.player.fieldZ,
      surfaceId = self.player.surfaceId,
      worldY = self.player.worldY,
      facing = self.player.facing,
      tick = self.tick + 1,
    })
    if intent then
      local result = self.scriptClient:consume(intent, self.tick + 1)
      local results = ScriptInteractionClient.RESULTS
      assert(
        result == results.started or result == results.blocked,
        "an interactable event must be bound: " .. tostring(intent.mapId)
      )
      return true
    end
  end

  local direction = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  if self.player.motion == "idle" and direction then
    local seam = self.navigationBoundary
      and self.navigationBoundary:crossesLogicalZone(self.currentMap, self.player, direction)
    local trigger = seam and nil
      or TransitionTrigger.inputPath(self.currentMap, self.player.fieldX, self.player.fieldZ, direction)
    if
      trigger
      and (
        trigger.kind == "directional"
        or not WarpSystem.isSuppressed(
          self.transition.suppression,
          self.currentMap.mapId,
          trigger.warp.x,
          trigger.warp.z
        )
      )
    then
      self.player.facing = direction
      self.transition:start(self.currentMap, trigger, direction)
      return true
    end
  end

  local walkPoseAtTickStart = self.player.motion == "walking" or self.player.motion == "turning"
  local movementInput = inputSnapshot
  if carriedBoundaryDirection then
    movementInput = {
      heldDirection = nil,
      pressedDirection = carriedBoundaryDirection,
    }
  end
  local motionAtPlayerUpdateStart = self.player.motion
  local stepCompleted = self.player:updateFixed(movementInput) == true
  if motionAtPlayerUpdateStart == "idle" and self.player.motion == "jumping" and self.audio then
    self.audio:play("SEQ_SE_DP_DANSA")
  end
  local completionDirection
  if motionAtPlayerUpdateStart == "walking" and stepCompleted then
    completionDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  elseif motionAtPlayerUpdateStart == "turning" and self.player.motion == "idle" then
    completionDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  end
  if stepCompleted then
    local zoneChanged = false
    if self.navigationBoundary then
      local boundaryResult = self.navigationBoundary:afterCommittedMove(self.currentMap, self.player, self.camera)
      if boundaryResult and boundaryResult.newMapId then
        zoneChanged = true
        self.currentMap = self.navigationBoundary.zoneController.currentMap
        self.transition.suppression = {
          mapId = boundaryResult.newMapId,
          fieldX = self.player.fieldX,
          fieldZ = self.player.fieldZ,
        }
      end
    end
    self:_emitTerrainResponse()
    if self.audio and not zoneChanged then
      self.audio:updateField()
    end
    local coordinateIntent = resolveCoordinate(self)
    if coordinateIntent then
      settleScriptHandoffPresentation(self)
      consumeScriptIntent(self, coordinateIntent)
      return true
    end
    local trigger = zoneChanged and nil
      or TransitionTrigger.stepPath(self.currentMap, self.player.fieldX, self.player.fieldZ, self.player.facing)
    if
      trigger
      and not WarpSystem.isSuppressed(
        self.transition.suppression,
        self.currentMap.mapId,
        trigger.warp.x,
        trigger.warp.z
      )
    then
      self.transition:start(self.currentMap, trigger, self.player.facing)
      return true
    end
    local passiveIntent = resolvePassiveSign(self)
    if passiveIntent then
      settleScriptHandoffPresentation(self)
      consumeScriptIntent(self, passiveIntent)
      return true
    end
  end
  if completionDirection then
    self._boundaryMovementDirection = completionDirection
  end
  if self.playerVisual then
    self.playerVisual:updateFixed(walkPoseAtTickStart)
  end
  self.camera:updateFixed(self:actorTarget())
  return false
end

function FieldSession:updateFixed(inputSnapshot)
  inputSnapshot = inputSnapshot or self.input:snapshot()
  local carriedBoundaryDirection = self._boundaryMovementDirection
  self._boundaryMovementDirection = nil
  if self:_updateTerrainAndTransition() then
    self:_advanceTick()
    return
  end

  if self:_updateApplication(inputSnapshot) then
    self:_advanceTick()
    return
  end

  if self:_updateDialogue(inputSnapshot) then
    self:_advanceTick()
    return
  end

  if self:_updateScript(inputSnapshot) then
    self:_advanceTick()
    return
  end

  if self:_updateStartMenu(inputSnapshot) then
    self:_advanceTick()
    return
  end

  if self:_updateInteractionAndMovement(inputSnapshot, carriedBoundaryDirection) then
    self:_advanceTick()
    return
  end
  self:_advanceTick()
end

function FieldSession:update(dt)
  assert(type(dt) == "number" and dt >= 0, "non-negative update dt required")
  self.accumulator = self.accumulator + dt
  local executed = 0
  while
    self.accumulator + ACCUMULATOR_EPSILON >= FieldSession.FIXED_DT and executed < FieldSession.MAX_CATCH_UP_TICKS
  do
    self.accumulator = self.accumulator - FieldSession.FIXED_DT
    self:updateFixed()
    executed = executed + 1
  end
  if self.accumulator + ACCUMULATOR_EPSILON >= FieldSession.FIXED_DT then
    local discarded = math.floor((self.accumulator + ACCUMULATOR_EPSILON) / FieldSession.FIXED_DT)
    self.accumulator = self.accumulator - discarded * FieldSession.FIXED_DT
  end
  return executed
end

-- The render interpolation factor. The catch-up cap and the drop branch can
-- leave a small float residual outside the tick interval, so the factor is
-- clamped defensively into [0, 1] for presentation consumers.
function FieldSession:renderAlpha()
  local alpha = self.accumulator / FieldSession.FIXED_DT
  return math.min(1, math.max(0, alpha))
end

return FieldSession
