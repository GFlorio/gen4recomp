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
-- Step 6 is wired through the optional `interactions`
-- service: `resolve(snapshot)` returns an immutable InteractionIntent for an
-- idle player's Action edge, which the session dispatches to
-- `scriptClient:consume(intent, tick)`. A consumed interaction owns the
-- tick, so the same edge can never also start a move or a warp. There is no
-- fallback client: the binding audit at load time guarantees every
-- interactable event is bound, so an unmapped intent is a composition fault.
-- The resolve service is invoked with the interactions table as self (colon
-- style), so implementations must declare a leading self parameter.

local WarpSystem = require("libs.engine.src.WarpSystem")

---@class FieldSessionOptions
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field player FieldPlayer
---@field camera FieldCamera
---@field transition FieldTransition
---@field actors FieldActorManager
---@field playerVisual FieldPlayerVisual?
---@field dialogue FieldDialogueController?
---@field input FieldInput
---@field interactions FieldSession.Interactions?
---@field scriptScheduler Scheduler?
---@field scriptClient ScriptInteractionClient?
---@field menuHost FieldMenuHost?
---@field contextChoice ContextChoiceProvider?
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
---@field dialogue FieldDialogueController?
---@field input FieldInput
---@field interactions FieldSession.Interactions?
---@field scriptScheduler Scheduler?
---@field scriptClient ScriptInteractionClient?
---@field menuHost FieldMenuHost?
---@field contextChoice ContextChoiceProvider?
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
-- of them is a composition fault rather than a partial-tick configuration.
function FieldSession.new(options)
  assert(options and options.versionId and options.currentMap, "field session identity required")
  assert(options.player and options.camera, "field session player and camera required")
  assert(options.transition, "field session transition required")
  assert(options.input, "field session input required")
  assert(options.actors, "field session actors required")
  assert(not options.interactions or options.scriptClient, "the interaction resolver and script client are paired")
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
    scriptClient = options.scriptClient --[[@as any]],
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
  self.transition:updateFixed()
  -- Keep the just-arrived tile stable until the application consumes the
  -- completion event and autosaves it, even when movement remains held.
  if self.transition.completed then
    self.input:clearEdges()
    self:_advanceTick()
    return
  end
  if self.transition.locked then
    self:_advanceTick()
    return
  end

  -- Modal ownership: while a dialogue is open the world freezes -- no queued
  -- visibility changes, no facing-warp check, no movement, no warp commit, no
  -- pose clocks, no camera motion. Only the dialogue reads this tick's input.
  -- Script-owned boxes are exempt: the script scheduler steps them from its
  -- own async phase and the script phase owns the tick instead.
  if
    self.dialogue
    and self.dialogue:isModal()
    and not (self.dialogue.isScriptOwned and self.dialogue:isScriptOwned())
  then
    self.dialogue:step(inputSnapshot)
    self:_advanceTick()
    return
  end

  -- Script phase : the field-script scheduler
  -- advances script-owned asynchronous work, polls tasks, promotes completed
  -- handoffs, runs ready contexts to yield, and resolves at most one new
  -- interaction. The session never steps the scheduler twice per tick.
  if self.scriptScheduler then
    local scriptOwnedInput = self.scriptScheduler:playerMovementLocked()
    local schedulerInput = {
      heldDirection = inputSnapshot.heldDirection,
      pressedDirection = inputSnapshot.pressedDirection,
      pressedAction = inputSnapshot.actionPressed or inputSnapshot.pressedAction,
      pressedCancel = inputSnapshot.cancelPressed or inputSnapshot.pressedCancel,
    }
    local menuModal = self.menuHost and self.menuHost:isModal()
    local contextChoiceModal = self.contextChoice and self.contextChoice:isActive()
    if menuModal or contextChoiceModal then
      assert(self.input, "modal field menu requires FieldInput")
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
    self.scriptScheduler:step(self.tick + 1, {
      heldDirection = schedulerInput.heldDirection,
      pressedDirection = schedulerInput.pressedDirection,
      pressedAction = schedulerInput.pressedAction,
      pressedCancel = schedulerInput.pressedCancel,
      menuEvents = schedulerInput.menuEvents,
      uiEvents = schedulerInput.uiEvents,
    })
    if self.menuHost then
      self.menuHost:advance(self.tick + 1)
    end
    local contextChoiceNowModal = self.contextChoice and self.contextChoice:isActive()
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
  if self.interactions and self.player.motion == "idle" and inputSnapshot.actionPressed then
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
      assert(
        result == "started" or result == "blocked",
        "an interactable event must be bound: " .. tostring(intent.mapId)
      )
      self:_advanceTick()
      return
    end
  end

  local direction = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  if self.transition.start and self.player.motion == "idle" and direction then
    local facingWarp = WarpSystem.findBlockedFacing(self.currentMap, self.player.fieldX, self.player.fieldZ, direction)
    if
      facingWarp
      and not WarpSystem.isSuppressed(self.transition.suppression, self.currentMap.mapId, facingWarp.x, facingWarp.z)
    then
      self.player.facing = direction
      self.transition:start(self.currentMap, facingWarp, direction)
      self:_advanceTick()
      return
    end
  end

  -- The pose clock treats a tick as walking if the player was mid-step at either
  -- end of it, so the gait phase carries across the tile commit instead of
  -- restarting on every arrival (the ROM's walk range spans two tiles).
  local walkingAtTickStart = self.player.motion == "walking"

  local stepCompleted = self.player:updateFixed(inputSnapshot) == true
  if stepCompleted and self.transition.start then
    local standingWarp = WarpSystem.findAt(self.currentMap, self.player.fieldX, self.player.fieldZ)
    if
      standingWarp
      and not WarpSystem.isSuppressed(
        self.transition.suppression,
        self.currentMap.mapId,
        self.player.fieldX,
        self.player.fieldZ
      )
    then
      self.transition:start(self.currentMap, standingWarp, self.player.facing)
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

function FieldSession:renderAlpha()
  return self.accumulator / FieldSession.FIXED_DT
end

return FieldSession
