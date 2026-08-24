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
local FieldEventResolver = require("libs.engine.src.FieldEventResolver")
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
---@field audio { updateField: fun(self: table) }?

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
---@field audio { updateField: fun(self: table) }?
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
    assert(type(options.audio.updateField) == "function", "field session audio field-policy update required")
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
    audio = options.audio,
    tick = 0,
    accumulator = 0,
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
  self:_advanceTick()
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
    if self.playerVisual and playerAdvanced then
      self.playerVisual:updateFixed(true)
    end
    self.camera:updateFixed(self:actorTarget())
    if self.transition.completed then
      self.camera:collapseRenderInterpolation()
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
    self.applicationHost:updateFixed(uiEvents)
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

  -- Script phase : the field-script scheduler
  -- advances script-owned asynchronous work, polls tasks, promotes completed
  -- handoffs, runs ready contexts to yield, and resolves at most one new
  -- interaction. The session never steps the scheduler twice per tick.
  -- Sampled before the scheduler runs this tick, so it reflects the
  -- pre-scheduler lock state even though the scheduler step below can
  -- itself release the lock; the post-scheduler observation right below
  -- the step call is a second, deliberately distinct read.
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
  -- A foreground root owns the field or a player lock suppresses movement
  -- and new triggers; the tick is consumed.
  if movementLockedAtTickStart or self.scriptScheduler:playerMovementLocked() then
    self:_advanceTick()
    return
  end

  -- Start Menu arbitration: a pending script reopen request (opcode 61's
  -- startMenuReopen service) opens the menu unconditionally at this point,
  -- then the menu edge is gated by the idle-boundary check (checked after
  -- the single script-scheduler step established the field lock state,
  -- before actor stepping, interaction resolution, warps, or player
  -- movement). The host's boolean answers "did the open consume this tick?":
  -- true for a successful open and for a fatal composition failure (the
  -- host has entered its terminal failed state, which must freeze the rest
  -- of this tick); false means the menu is unavailable and the field
  -- continues stepping normally. The input snapshot has already consumed a
  -- simultaneous Action edge, and the menu owns the tick, so no edge
  -- clearing is part of this policy.
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

  if self.transition.suppression then
    self.transition.suppression = WarpSystem.updateSuppression(
      self.transition.suppression,
      self.currentMap.mapId,
      self.player.fieldX,
      self.player.fieldZ
    )
  end

  -- Queued visibility changes land before anything reads occupancy or starts a
  -- move, so collision and the draw list never disagree within a tick.
  self.actors:step(self.tick + 1)

  -- HGSS checks a passive sign before the idle Action and standing-input
  -- paths. It is deliberately limited to a north-facing type-one event.
  local passiveDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  if self.player.motion == "idle" and passiveDirection == self.player.facing then
    local intent = resolvePassiveSign(self)
    if intent then
      settleScriptHandoffPresentation(self)
      consumeScriptIntent(self, intent)
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
    local trigger = TransitionTrigger.inputPath(self.currentMap, self.player.fieldX, self.player.fieldZ, direction)
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
      self:_advanceTick()
      return
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
      settleScriptHandoffPresentation(self)
      consumeScriptIntent(self, coordinateIntent)
      return
    end

    -- Standing-trigger path: a completed step onto a warp tile
    -- evaluates the HGSS step path -- north/panel/ladder-down/escalator
    -- behaviors only; direction-gated warps wait for the facing path above.
    local trigger =
      TransitionTrigger.stepPath(self.currentMap, self.player.fieldX, self.player.fieldZ, self.player.facing)
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
      self:_advanceTick()
      return
    end
    local passiveIntent = resolvePassiveSign(self)
    if passiveIntent then
      settleScriptHandoffPresentation(self)
      consumeScriptIntent(self, passiveIntent)
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
