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
-- fallback client: the binding audit at load time guarantees every
-- interactable event is bound, so an unmapped intent is a composition fault.
-- The resolve service is invoked with the interactions table as self (colon
-- style), so implementations must declare a leading self parameter.
--
-- The session owns no 60 Hz audio timing: its audio collaborator receives
-- only the field-policy update (`updateField`) once per fixed tick. The 60 Hz
-- sound-frame clock is the runtime's wall-clock accumulator.

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
---@field eventState { getVar: fun(self: table, id: integer): integer }
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field signpost FieldSignpostController
---@field applicationHost FieldApplicationHost the one application modal owner (Start Menu and its destinations)
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field audio { updateField: fun(self: table) }?
---@field initController table|nil
---@field enterMapActors fun()?
---@field autoAcknowledgePresentation boolean?
---@field constructActorsDuringTransition boolean?

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
---@field eventState { getVar: fun(self: table, id: integer): integer }
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field signpost FieldSignpostController the fixed-tick signpost controller (save-gate interrogation only; the scheduler steps it)
---@field applicationHost FieldApplicationHost the one application modal owner (Start Menu and its destinations)
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field audio { updateField: fun(self: table) }?
---@field initController table|nil
---@field enterMapActors fun()?
---@field mapEntryStage string?
---@field childResumePending boolean
---@field autoAcknowledgePresentation boolean
---@field constructActorsDuringTransition boolean
---@field tick integer
---@field accumulator number
local FieldSession = {}
FieldSession.__index = FieldSession

-- The DS field cadence: 30 fixed ticks per second, owned here.
FieldSession.FIXED_HZ = 30
FieldSession.FIXED_DT = 1 / FieldSession.FIXED_HZ
FieldSession.MAX_CATCH_UP_TICKS = 5

-- Float slack so a render delta that lands exactly on a tick boundary does
-- not leave a stale full tick in the accumulator.
local ACCUMULATOR_EPSILON = 1e-12

local HIDDEN_ENTRY_STAGES = {
  transition = true,
  transition_running = true,
  actors = true,
  load = true,
  load_running = true,
}

local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local function collapseCameraInterpolation(camera)
  if camera.collapseRenderInterpolation then
    camera:collapseRenderInterpolation()
  end
end

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
    options.player and options.player.updateFixed and options.camera and options.camera.updateFixed,
    "field session player and camera required"
  )
  assert(
    options.transition and options.transition.updateFixed and options.transition.start,
    "field session transition required"
  )
  assert(options.actors and options.actors.step, "field session actors required")
  assert(options.input and options.input.snapshot, "field session input required")
  assert(options.dialogue and options.dialogue.isModal, "field session dialogue required")
  assert(
    options.scriptScheduler
      and options.scriptScheduler.step
      and options.scriptScheduler.playerInputLocked
      and options.scriptScheduler.foregroundEnvironmentId,
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
    assert(type(options.audio.updateField) == "function", "field session audio field-policy update required")
  end
  local session = setmetatable({
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
    audio = options.audio,
    initController = options.initController,
    enterMapActors = options.enterMapActors,
    mapEntryStage = nil,
    childResumePending = false,
    autoAcknowledgePresentation = options.autoAcknowledgePresentation == true,
    constructActorsDuringTransition = options.constructActorsDuringTransition == true,
    tick = 0,
    accumulator = 0,
  }, FieldSession)
  return session
end

function FieldSession:beginMapEntry()
  assert(type(self.enterMapActors) == "function", "map actor entry capability required")
  assert(self.initController and self.initController.startLifecycle, "map lifecycle controller required")
  self.mapEntryStage = "transition"
end

function FieldSession:onChildApplicationResume()
  self.childResumePending = true
end

function FieldSession:destinationWorldPresentable()
  return not HIDDEN_ENTRY_STAGES[self.mapEntryStage]
end

function FieldSession:acknowledgeDestinationPresentation()
  if self.mapEntryStage == "await_presentation" then
    self.mapEntryStage = "resume"
  end
end

local function hasEntryLifecycle(self, lifecycle)
  return self.initController:hasLifecycle(lifecycle)
end

-- Advances one map-entry boundary. A running lifecycle is left for the normal
-- scheduler phase, which remains the sole script execution point.
function FieldSession:_advanceMapEntryBoundary()
  local stage = self.mapEntryStage
  if not stage then
    return false
  end
  if stage == "transition" then
    if self.scriptScheduler:foregroundEnvironmentId() ~= nil then
      return false
    end
    if hasEntryLifecycle(self, "on_transition") then
      if self.initController:startLifecycle("on_transition", self.tick + 1) then
        -- Headless production boots acknowledge presentation automatically;
        -- construct actors at that boundary so the transition script can
        -- address the destination map. The observable presentation path
        -- still waits for the foreground lifecycle to finish.
        self.mapEntryStage = self.constructActorsDuringTransition and "actors" or "transition_running"
      end
    else
      self.mapEntryStage = "actors"
    end
    return true
  elseif stage == "transition_running" then
    if self.scriptScheduler:foregroundEnvironmentId() ~= nil then
      return false
    end
    self.mapEntryStage = "actors"
    return true
  elseif stage == "actors" then
    self.enterMapActors()
    self.mapEntryStage = "load"
    return true
  elseif stage == "load" then
    if self.scriptScheduler:foregroundEnvironmentId() ~= nil then
      return false
    end
    if hasEntryLifecycle(self, "on_load") then
      if self.initController:startLifecycle("on_load", self.tick + 1) then
        self.mapEntryStage = "load_running"
      end
    else
      self.mapEntryStage = "await_presentation"
    end
    return true
  elseif stage == "load_running" then
    if self.scriptScheduler:foregroundEnvironmentId() ~= nil then
      return false
    end
    self.mapEntryStage = "await_presentation"
    return true
  elseif stage == "await_presentation" then
    if self.autoAcknowledgePresentation then
      self:acknowledgeDestinationPresentation()
      return true
    end
    return false
  elseif stage == "resume" then
    if self.scriptScheduler:foregroundEnvironmentId() ~= nil then
      return false
    end
    if hasEntryLifecycle(self, "on_resume") then
      if self.initController:startLifecycle("on_resume", self.tick + 1) then
        self.mapEntryStage = "resume_running"
      end
    else
      self.mapEntryStage = "ready"
    end
    return true
  elseif stage == "resume_running" then
    if self.scriptScheduler:foregroundEnvironmentId() ~= nil then
      return false
    end
    self.mapEntryStage = "ready"
    return true
  elseif stage == "ready" then
    self.mapEntryStage = nil
    return false
  end
  error("unknown map entry stage " .. tostring(stage))
end

function FieldSession:actorTarget()
  return { x = self.player.worldX, y = self.player.worldY, z = self.player.worldZ }
end

local function isForegroundActive(scheduler)
  return scheduler:foregroundEnvironmentId() ~= nil
end

local function isPlayerInputLocked(scheduler)
  return scheduler:playerInputLocked()
end

-- The idle-boundary gate for the Start Menu open edge: the menu may open
-- only at a settled field boundary -- player idle, transition idle, no
-- dialogue/signpost/script menu/context choice, no active foreground
-- script owner and no explicit player input lock. Any non-idle player
-- motion means "not idle"; the active application branch above has already
-- returned before this code runs.
---@return boolean
local function canOpenStartMenu(self)
  return self.player.motion == "idle"
    and self.transition.phase == FieldTransition.PHASES.idle
    and not self.dialogue:isModal()
    and not self.signpost:isModal()
    and not self.menuHost:isModal()
    and not self.contextChoice:isActive()
    and not isForegroundActive(self.scriptScheduler)
    and not isPlayerInputLocked(self.scriptScheduler)
end

function FieldSession:_advanceTick()
  self.fieldEntranceIndicator:updateFixed({
    map = self.currentMap,
    player = self.player,
    transition = { ownsField = self.transition.phase == FieldTransition.PHASES.idle },
  })
  self.tick = self.tick + 1
end

local function resolveCoordinate(self)
  return self.eventResolver.resolveCoordinate(self.currentMap, self.player, self.eventState)
end

local function resolveCoordinateAhead(self, direction)
  local offset = assert(DIRECTION_DELTAS[direction], "coordinate probe direction required")
  return self.eventResolver.resolveCoordinate(self.currentMap, {
    fieldX = self.player.fieldX + offset.x,
    fieldZ = self.player.fieldZ + offset.z,
    facing = direction,
  }, self.eventState)
end

local function hasCoordinateAhead(self, direction)
  local offset = assert(DIRECTION_DELTAS[direction], "coordinate probe direction required")
  local targetX = self.player.fieldX + offset.x
  local targetZ = self.player.fieldZ + offset.z
  local events = self.currentMap.fieldData.events and self.currentMap.fieldData.events.coordinates or {}
  for _, event in ipairs(events) do
    if
      targetX >= event.x
      and targetX < event.x + event.width
      and targetZ >= event.z
      and targetZ < event.z + event.height
    then
      return true
    end
  end
  return false
end

local function hasCoordinateAt(self, fieldX, fieldZ)
  local events = self.currentMap.fieldData.events and self.currentMap.fieldData.events.coordinates or {}
  for _, event in ipairs(events) do
    if
      fieldX >= event.x
      and fieldX < event.x + event.width
      and fieldZ >= event.z
      and fieldZ < event.z + event.height
    then
      return true
    end
  end
  return false
end

local function resolvePassiveSign(self)
  return self.eventResolver.resolvePassiveSign(self.currentMap, self.player)
end

function FieldSession:updateFixed(inputSnapshot)
  -- Ordinary field-audio runs on its semantic events (step-completion and
  -- map-entry), not at the top of every fixed tick. updateField is the
  -- test/legacy entry for those events; see FieldPlayer step commit and
  -- FieldAudioController:enterMap.
  inputSnapshot = inputSnapshot or self.input:snapshot()
  -- The door/stair choreography drives the player during the locked
  -- transition: the pose clock hears the walking state at tick start, the
  -- camera tracks the continuous XYZ, and the scene's animated props
  -- advance under the choreographed locked tick. The camera samples on
  -- every locked tick and on the completion tick -- never coupled to
  -- player motion -- so interpolation pairs collapse instead of replaying.
  local walkingAtTickStart = self.player.motion == "walking"
  local playerAdvanced = self.transition:updateFixed()
  if self.transition.locked or self.transition.completed then
    if not playerAdvanced and self.player.motion == "idle" then
      self.player:collapseRenderInterpolation()
    end
    self.currentMap:updateAnimated()
    if playerAdvanced and self.playerVisual then
      self.playerVisual:updateFixed(walkingAtTickStart)
    end
    self.camera:updateFixed(self:actorTarget())
    if self.transition.completed then
      collapseCameraInterpolation(self.camera)
    end
    -- Keep the just-arrived tile stable until the application consumes the
    -- completion event and autosaves it, even when movement remains held.
    if self.transition.completed and self.input.clearEdges then
      self.input:clearEdges()
    end
    self:_advanceTick()
    return
  end

  -- Application ownership: while the application host is active (Start Menu
  -- or a child application, in any of its phases) it is the one modal owner
  -- -- the session steps only it, once per fixed tick, and freezes world
  -- simulation (no player/actors/scheduler/interaction/movement). Opening a
  -- second incompatible modal is a programming invariant, asserted here.
  if self.applicationHost:isActive() then
    assert(
      not self.dialogue:isModal() and not self.signpost:isModal() and not self.menuHost:isModal(),
      "the application host owns the tick; no other modal may be active"
    )
    local uiEvents = self.input:uiSnapshot(self.tick + 1)
    -- While the Start Menu is active, the menu button has the same close
    -- semantics as HGSS X: a fresh menu edge becomes the controller's menu
    -- event. A child application's own input policy applies instead.
    if inputSnapshot.menuPressed then
      uiEvents[#uiEvents + 1] = { type = "menu" }
    end
    local status = self.applicationHost.status and self.applicationHost:status() or nil
    local wasApplication = status and status.phase == "application"
    self.applicationHost:updateFixed(uiEvents)
    local afterStatus = self.applicationHost.status and self.applicationHost:status() or nil
    if wasApplication and afterStatus and afterStatus.phase == "fading_in" then
      self:onChildApplicationResume()
    end
    self:_advanceTick()
    return
  end

  -- Modal ownership: while a dialogue is open the world steps freeze -- no
  -- queued visibility changes, no facing-warp check, no movement, no warp
  -- commit, no pose clocks, no camera motion. Only the dialogue reads this
  -- tick's input, and the scene animation clock keeps advancing: HGSS's
  -- field update path does not couple map-prop animation progression to
  -- dialogue ownership, so wind/machines keep running while a message box
  -- is up.
  -- Script-owned boxes are exempt: the script scheduler steps them from its
  -- own async phase and the script phase owns the tick instead.
  if self.dialogue:isModal() and not (self.dialogue.isScriptOwned and self.dialogue:isScriptOwned()) then
    self.currentMap:updateAnimated()
    self.dialogue:step(inputSnapshot)
    self:_advanceTick()
    return
  end

  -- Field animation clock: the world's animated props advance once per tick
  -- -- ordinary movement, script-locked ticks, interaction ticks, the
  -- transition-start tick, and modal-dialogue ticks alike (transition ticks
  -- advance it in the branch above). FieldSession owns this clock; the map
  -- aggregate fans one call out to the central scene runtime and the
  -- neighbor coverage runtime. No other module steps it.
  self.currentMap:updateAnimated()

  if self.mapEntryStage then
    assert(self.initController and self.initController.hasLifecycle, "map lifecycle presence query required")
    if self:_advanceMapEntryBoundary() then
      self:_advanceTick()
      return
    end
  elseif self.childResumePending and self.scriptScheduler:foregroundEnvironmentId() == nil then
    self.childResumePending = false
    if self.initController:hasLifecycle("on_resume") then
      assert(self.initController:startLifecycle("on_resume", self.tick + 1))
    end
    self:_advanceTick()
    return
  elseif
    self.initController
    and not self.initController.startLifecycle
    and self.initController:evaluate(self.tick + 1)
  then
    self:_advanceTick()
    return
  end

  -- Script phase : the field-script scheduler
  -- advances script-owned asynchronous work, polls tasks, promotes completed
  -- handoffs, runs ready contexts to yield, and resolves at most one new
  -- interaction. The session never steps the scheduler twice per tick.
  -- Sampled before the scheduler runs this tick, so it reflects the
  -- pre-scheduler lock state even though the scheduler step below can
  -- itself release the lock; the post-scheduler observation right below
  -- the step call is a second, deliberately distinct read.
  local playerInputLockedAtTickStart = self.scriptScheduler:playerInputLocked()
  local schedulerInput = {
    heldDirection = inputSnapshot.heldDirection,
    pressedDirection = inputSnapshot.pressedDirection,
    pressedAction = inputSnapshot.actionPressed,
    pressedCancel = inputSnapshot.cancelPressed,
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
  if self.mapEntryStage then
    if self:_advanceMapEntryBoundary() or self.mapEntryStage ~= nil then
      self:_advanceTick()
      return
    end
  end

  local playerInputLockedAfterScheduler = isPlayerInputLocked(self.scriptScheduler)
  local foregroundActive = isForegroundActive(self.scriptScheduler)
  local inputSuppressedThisTick = playerInputLockedAtTickStart or playerInputLockedAfterScheduler

  -- Start Menu arbitration: a pending script reopen request (opcode 61's
  -- startMenuReopen service) opens the menu unconditionally at this point,
  -- then the menu edge is gated by the idle-boundary check (checked after
  -- the single script-scheduler step established the field lock state,
  -- before actor stepping, interaction resolution, warps, or player
  -- movement). The host's boolean answers "did the open consume this tick?":
  -- true for a successful open and for a fatal composition failure (the
  -- host has entered its terminal failed state, which must freeze the rest
  -- of this tick); false means the menu is unavailable and the field
  -- continues stepping normally. This arbitration freezes world
  -- presentation (actors, player, camera) on its tick, so it runs before
  -- the actor step.
  if self.applicationHost:takeReopen(self.tick + 1) then
    self:_advanceTick()
    return
  end
  if inputSnapshot.menuPressed and canOpenStartMenu(self) then
    if self.applicationHost:requestOpen(self.tick + 1) then
      self:_advanceTick()
      return
    end
  end

  -- World presentation advances even while a foreground script runs, and
  -- exactly once per world-advancing tick (not once per same-run presence
  -- flush). Input suppression does not freeze it.
  self.actors:step(self.tick + 1)

  if self.childResumePending then
    self:_advanceTick()
    return
  end

  if self.initController and self.initController.startLifecycle then
    local evaluateFrame = self.initController.evaluateFrame
    if evaluateFrame and evaluateFrame(self.initController, self.tick + 1) then
      self:_advanceTick()
      return
    end
  end

  if inputSuppressedThisTick then
    if self.playerVisual then
      local walkingAtTickStart = self.player.motion == "walking"
      self.playerVisual:updateFixed(walkingAtTickStart)
    end
    self.camera:updateFixed(self:actorTarget())
    self:_advanceTick()
    return
  end

  -- Active foreground blocks acquiring another foreground owner even without
  -- an explicit player lock, but does not suppress player movement when
  -- input is not locked.

  if self.transition.suppression then
    self.transition.suppression = WarpSystem.updateSuppression(
      self.transition.suppression,
      self.currentMap.mapId,
      self.player.fieldX,
      self.player.fieldZ
    )
  end

  if not foregroundActive then
    local passiveDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
    if self.player.motion == "idle" and passiveDirection == self.player.facing then
      local intent = resolvePassiveSign(self)
      if intent then
        self.scriptClient:consume(intent, self.tick + 1)
        self:_advanceTick()
        return
      end
    end

    -- An idle player's Action edge resolves an interaction
    -- before movement or warps are evaluated. A consumed interaction owns the
    -- tick (the dialogue becomes modal on it), so the same edge cannot also
    -- start a move or warp. The edge itself was already consumed by the input
    -- snapshot, so a held Action cannot re-open anything.
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
        -- The script client resolves the binding, starts the composed script,
        -- and runs it during this tick. There is no fallback client: the
        -- binding audit at load time guarantees every interactable event is
        -- bound, so an unmapped intent here is a composition fault, not a
        -- silent absorption.
        local result = self.scriptClient:consume(intent, self.tick + 1)
        local results = ScriptInteractionClient.RESULTS
        assert(
          result == results.started or result == results.blocked,
          "an interactable event must be bound: " .. tostring(intent.mapId)
        )
        self:_advanceTick()
        return
      end
    end

    -- Facing-trigger path: an idle player pressing a direction
    -- evaluates the HGSS input path -- a blocked DOOR tile ahead, or a
    -- direction-gated standing door/stairs/warp on the player's own tile.
    local direction = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
    if self.player.motion == "idle" and direction then
      -- A coordinate event on the tile being entered owns the step, even when
      -- that tile is also a direction-triggered warp. The ROM evaluates the
      -- arrival event after the step; pre-empting it here would leave the
      -- generated coordinate script unresolved.
      local coordinateAhead = resolveCoordinateAhead(self, direction)
      local trigger = TransitionTrigger.inputPath(self.currentMap, self.player.fieldX, self.player.fieldZ, direction)
      if
        trigger
        and coordinateAhead == nil
        and not hasCoordinateAhead(self, direction)
        and not WarpSystem.isSuppressed(
          self.transition.suppression,
          self.currentMap.mapId,
          trigger.warp.x,
          trigger.warp.z
        )
      then
        self.player.facing = direction
        self.transition:start(self.currentMap, trigger, direction)
        self:_advanceTick()
        return
      end
    end
  end

  -- The pose clock treats a tick as walking if the player was mid-step at either
  -- end of it, so the gait phase carries across the tile commit instead of
  -- restarting on every arrival (the ROM's walk range spans two tiles).
  local walkingAtTickStart = self.player.motion == "walking"

  local stepCompleted = self.player:updateFixed(inputSnapshot) == true
  if stepCompleted then
    if self.audio then
      self.audio:updateField()
    end
    local coordinateIntent = resolveCoordinate(self)
    if coordinateIntent then
      local coordinateResult = self.scriptClient:consume(coordinateIntent, self.tick + 1)
      assert(
        coordinateResult == ScriptInteractionClient.RESULTS.started
          or coordinateResult == ScriptInteractionClient.RESULTS.blocked,
        "a coordinate event must be bound: " .. tostring(coordinateIntent.mapId)
      )
      if self.playerVisual then
        self.playerVisual:settle()
      end
      self.player:collapseRenderInterpolation()
      self.camera:updateFixed(self:actorTarget())
      collapseCameraInterpolation(self.camera)
      self:_advanceTick()
      return
    end
    -- Standing-trigger path: a completed step onto a warp tile
    -- evaluates the HGSS step path -- north/panel/ladder-down/escalator
    -- behaviors only; direction-gated warps wait for the facing path above.
    local trigger =
      TransitionTrigger.stepPath(self.currentMap, self.player.fieldX, self.player.fieldZ, self.player.facing)
    if
      trigger
      and not hasCoordinateAt(self, self.player.fieldX, self.player.fieldZ)
      and not WarpSystem.isSuppressed(
        self.transition.suppression,
        self.currentMap.mapId,
        trigger.warp.x,
        trigger.warp.z
      )
    then
      self.transition:start(self.currentMap, trigger, self.player.facing)
      self:_advanceTick()
      return
    end
    local passiveIntent = resolvePassiveSign(self)
    if passiveIntent then
      self.scriptClient:consume(passiveIntent, self.tick + 1)
      if self.playerVisual then
        self.playerVisual:settle()
      end
      self.player:collapseRenderInterpolation()
      self.camera:updateFixed(self:actorTarget())
      collapseCameraInterpolation(self.camera)
      self:_advanceTick()
      return
    end
  end
  -- Pose clocks advance only on a tick that could change the world, so a fade or
  -- a locked transition freezes animation instead of walking it in place.
  if self.playerVisual then
    self.playerVisual:updateFixed(walkingAtTickStart)
  end
  self.camera:updateFixed(self:actorTarget())
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
