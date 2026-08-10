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
-- idle player's Action edge and `consume(intent)` dispatches it to the
-- configured interaction client (the pre-script adapter). A consumed
-- interaction owns the tick, so the same edge can never also start a move or
-- a warp. The session never imports the adapter; FieldState constructs the
-- replacement point. The service methods are invoked with the interactions
-- table as self (colon style), so implementations must declare a leading
-- self parameter.

local WarpSystem = require("libs.engine.src.WarpSystem")

---@class FieldSessionOptions
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field actor FieldPlayer
---@field player FieldPlayer?
---@field camera FieldCamera
---@field transition FieldTransition?
---@field actors FieldActorManager?
---@field playerVisual FieldPlayerVisual?
---@field dialogue FieldDialogueController?
---@field input FieldInput?
---@field interactions FieldSession.Interactions?
---@field scriptScheduler Scheduler?
---@field scriptClient ScriptInteractionClient?
---@field coverage fun(session: FieldSession)?

---@class FieldSession.Interactions
---@field resolve fun(self: FieldSession.Interactions, snapshot: InteractionResolverSnapshot): InteractionIntent?
---@field consume fun(self: FieldSession.Interactions, intent: InteractionIntent): boolean

---@class FieldSession
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field actor FieldPlayer
---@field player FieldPlayer
---@field camera FieldCamera
---@field transition FieldTransition?
---@field actors FieldActorManager?
---@field playerVisual FieldPlayerVisual?
---@field dialogue FieldDialogueController?
---@field input FieldInput?
---@field interactions FieldSession.Interactions?
---@field scriptScheduler Scheduler?
---@field scriptClient ScriptInteractionClient?
---@field coverage fun(session: FieldSession)?
---@field tick integer
---@field accumulator number
local FieldSession = {}
FieldSession.__index = FieldSession

FieldSession.FIXED_DT = 1 / 30
FieldSession.MAX_CATCH_UP_TICKS = 5

-- Float slack so a render delta that lands exactly on a tick boundary does
-- not leave a stale full tick in the accumulator.
local ACCUMULATOR_EPSILON = 1e-12

---@param options FieldSessionOptions
---@return FieldSession
function FieldSession.new(options)
  assert(options and options.versionId and options.currentMap, "field session identity required")
  assert(options.actor and options.camera, "field session actor and camera required")
  return setmetatable({
    versionId = options.versionId,
    currentMap = options.currentMap,
    actor = options.actor,
    player = options.player or options.actor,
    camera = options.camera,
    transition = options.transition,
    actors = options.actors,
    playerVisual = options.playerVisual,
    dialogue = options.dialogue,
    input = options.input,
    interactions = options.interactions,
    scriptScheduler = options.scriptScheduler,
    scriptClient = options.scriptClient --[[@as any]],
    coverage = options.coverage,
    tick = 0,
    accumulator = 0,
  }, FieldSession)
end

function FieldSession:actorTarget()
  return { x = self.actor.worldX, y = self.actor.worldY, z = self.actor.worldZ }
end

function FieldSession:_advanceTick()
  self.tick = self.tick + 1
end

function FieldSession:updateFixed(inputSnapshot)
  inputSnapshot = inputSnapshot or (self.input and self.input:snapshot()) or {}
  if self.transition and self.transition.updateFixed then
    self.transition:updateFixed()
    -- Keep the just-arrived tile stable until the application consumes the
    -- completion event and autosaves it, even when movement remains held.
    if self.transition.completed then
      if self.input and self.input.clearEdges then
        self.input:clearEdges()
      end
      self:_advanceTick()
      return
    end
    if self.transition.locked then
      self:_advanceTick()
      return
    end
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
    self.scriptScheduler:step(self.tick + 1, {
      heldDirection = inputSnapshot.heldDirection,
      pressedDirection = inputSnapshot.pressedDirection,
      pressedAction = inputSnapshot.actionPressed or inputSnapshot.pressedAction,
      pressedCancel = inputSnapshot.cancelPressed or inputSnapshot.pressedCancel,
    })
    -- A foreground root owns the field or a player lock suppresses movement
    -- and new triggers; the tick is consumed.
    if self.scriptScheduler:playerMovementLocked() then
      self:_advanceTick()
      return
    end
  end

  if self.transition and self.transition.suppression then
    self.transition.suppression = WarpSystem.updateSuppression(
      self.transition.suppression,
      self.currentMap.mapId,
      self.player.fieldX,
      self.player.fieldZ
    )
  end

  -- Queued visibility changes land before anything reads occupancy or starts a
  -- move, so collision and the draw list never disagree within a tick.
  if self.actors then
    self.actors:step(self.tick + 1)
  end

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
      -- The script client replaces the pre-script adapter: it resolves the
      -- binding, starts the composed script, and runs it during this tick.
      -- Unmapped intents fall through to the fixture client.
      if self.scriptClient then
        local result = self.scriptClient:consume(intent, self.tick + 1)
        if result == "started" or result == "blocked" then
          self:_advanceTick()
          return
        end
      end
      if self.interactions:consume(intent) then
        self:_advanceTick()
        return
      end
    end
  end

  local direction = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  if self.transition and self.transition.start and self.player.motion == "idle" and direction then
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

  local stepCompleted = false
  if self.player.updateFixed then
    stepCompleted = self.player:updateFixed(inputSnapshot) == true
  end
  if stepCompleted and self.transition and self.transition.start then
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
