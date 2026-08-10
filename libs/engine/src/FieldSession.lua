-- Runs the authoritative field simulation at 30 fixed ticks per second, the
-- DS field cadence (the fixed-step accumulator is render-delta independent).
-- Player movement advances before the camera so both consume the same
-- continuous XYZ. A modal dialogue owns the tick: once the fade/transition
-- phase (which cannot be active while a dialogue is open) has advanced, the
-- session steps only the dialogue and returns, so movement, warps,
-- interactions, and actor pose clocks freeze until the dialogue closes.
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

local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local WarpSystem = require("libs.engine.src.WarpSystem")
local ScriptInteractionClient = require("libs.engine.src.script.ScriptInteractionClient")

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
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field coverage fun(session: FieldSession)?

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
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field coverage fun(session: FieldSession)?
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
    options.scriptScheduler and options.scriptScheduler.step and options.scriptScheduler.playerMovementLocked,
    "field session script scheduler required"
  )
  assert(options.scriptClient and options.scriptClient.consume, "field session script client required")
  assert(options.menuHost and options.menuHost.isModal and options.menuHost.advance, "field session menu host required")
  assert(options.contextChoice and options.contextChoice.isActive, "field session context choice required")
  assert(options.interactions and options.interactions.resolve, "field session interaction resolver required")
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
    scriptScheduler = options.scriptScheduler,
    scriptClient = options.scriptClient,
    menuHost = options.menuHost,
    contextChoice = options.contextChoice,
    coverage = options.coverage,
    tick = 0,
    accumulator = 0,
  }, FieldSession)
end

function FieldSession:actorTarget()
  return { x = self.player.worldX, y = self.player.worldY, z = self.player.worldZ }
end

function FieldSession:_advanceTick()
  self.tick = self.tick + 1
end

function FieldSession:updateFixed(inputSnapshot)
  inputSnapshot = inputSnapshot or self.input:snapshot()
  -- The door/stair choreography drives the player during the locked
  -- transition: the pose clock hears the walking state at tick start, the
  -- camera tracks the continuous XYZ, and the scene's animated props (the
  -- door open/close) advance under the choreographed locked tick.
  local walkingAtTickStart = self.player.motion == "walking"
  local moved = self.transition:updateFixed()
  -- Keep the just-arrived tile stable until the application consumes the
  -- completion event and autosaves it, even when movement remains held.
  if self.transition.completed then
    self.input:clearEdges()
    self:_advanceTick()
    return
  end
  if self.transition.locked then
    if (self.transition.doorActive or self.transition.stairActive) and self.currentMap.sceneRuntime then
      self.currentMap.sceneRuntime:updateAnimated()
    end
    if moved and self.playerVisual then
      self.playerVisual:updateFixed(walkingAtTickStart)
      self.camera:updateFixed(self:actorTarget())
    end
    self:_advanceTick()
    return
  end

  -- Modal ownership: while a dialogue is open the world freezes -- no queued
  -- visibility changes, no facing-warp check, no movement, no warp commit, no
  -- pose clocks, no camera motion. Only the dialogue reads this tick's input.
  -- Script-owned boxes are exempt: the script scheduler steps them from its
  -- own async phase and the script phase owns the tick instead.
  if self.dialogue:isModal() and not (self.dialogue.isScriptOwned and self.dialogue:isScriptOwned()) then
    self.dialogue:step(inputSnapshot)
    self:_advanceTick()
    return
  end

  -- Script phase : the field-script scheduler
  -- advances script-owned asynchronous work, polls tasks, promotes completed
  -- handoffs, runs ready contexts to yield, and resolves at most one new
  -- interaction. The session never steps the scheduler twice per tick.
  local scriptOwnedInput = self.scriptScheduler:playerMovementLocked()
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
  -- A foreground root owns the field or a player lock suppresses movement
  -- and new triggers; the tick is consumed.
  if scriptOwnedInput or self.scriptScheduler:playerMovementLocked() then
    self:_advanceTick()
    return
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
      and not WarpSystem.isSuppressed(
        self.transition.suppression,
        self.currentMap.mapId,
        trigger.warp.x,
        trigger.warp.z
      )
    then
      self.player.facing = direction
      self.transition:start(self.currentMap, trigger.warp, direction)
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
      self.transition:start(self.currentMap, trigger.warp, self.player.facing)
    end
  end
  -- Pose clocks advance only on a tick that could change the world, so a fade or
  -- a locked transition freezes animation instead of walking it in place.
  if self.playerVisual then
    self.playerVisual:updateFixed(walkingAtTickStart)
  end
  self.camera:updateFixed(self:actorTarget())
  if self.coverage then
    self.coverage(self)
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
