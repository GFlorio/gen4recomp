-- movement task implementation: a serializable actor movement plan driven by
-- the task's own one-poll-per-tick cadence (engine-owned advancement is
-- permitted, but the poll cadence keeps the plan deterministic and
-- domain-owned). `apply_movement` starts the plan and continues same-tick;
-- `move` blocks on it. Each poll advances the current action by one tick,
-- applies the actor's field position and facing through the actor world, and
-- on plan completion unregisters from the environment's movement generation
-- (the barrier predicate) and completes the record. An unsupported movement
-- action is an attributed fault: the plan must never skip source commands.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local EmoteSoundCatalog = require("libs.hgss.src.script.EmoteSoundCatalog")

local MovementTask = {}

MovementTask.type = "movement"
MovementTask.version = 1

-- The only source-proven automatic movement-emote sound: HGSS spawns the
-- shared exclamation/question field-effect object with a "play sound" flag
-- set for both MapObjectMovementCmd075 (exclamation) and
-- MapObjectMovementCmd103 (question), and the effect's init function
-- (ov01_0220059C) issues PlaySE(SEQ_SE_DP_DECIDE) when that flag is set.
-- Only the exclamation mapping is wired here: this task owns the
-- exclamation movement action and its own flag is confirmed set; a question
-- mapping stays unproven at this call site until traced independently.
local EMOTE_SOUND_CATALOG = EmoteSoundCatalog.new({ exclamation = "SEQ_SE_DP_DECIDE" })

-- Field-coordinate step deltas per direction (north decreases fieldZ).
local DIRECTION_DELTA = {
  north = { fieldX = 0, fieldZ = -1 },
  south = { fieldX = 0, fieldZ = 1 },
  west = { fieldX = -1, fieldZ = 0 },
  east = { fieldX = 1, fieldZ = 0 },
}

-- Actions applied without tick advancement; each performs a real actor
-- operation (visibility and animation state ride the actor record).
local IMMEDIATE_ACTIONS = {
  set_visible = true,
  lock_facing = true,
  unlock_facing = true,
  pause_animation = true,
  resume_animation = true,
}

---@param spec table
---@param ctx table
---@return table state
function MovementTask.create(spec, ctx)
  local node = spec.node or spec
  local actor = assert(node.actor or spec.actor, "movement task requires an actor")
  local sequence = assert(node.movement or spec.sequence, "movement task requires a sequence")
  if #sequence == 0 then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "movement sequence is empty", { scriptId = ctx.instance.scriptId })
  end
  -- One ownership boundary for every movement entry point: a raw task
  -- descriptor (ctx.tasks.movement) and a compiled move/apply_movement node
  -- both reject a second movement on an actor this environment already
  -- moves.
  local actorId = type(actor) == "string" and actor or (actor and actor.id) or actor
  local existing = ctx.scheduler:activeMovementForActor(ctx.environment.environmentId, actorId)
  if existing ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_ACTOR_BUSY,
      "another foreground task already moves this actor",
      { scriptId = ctx.instance.scriptId, actor = actorId, taskId = existing }
    )
  end
  local position = ctx.services.actors:getPosition(actor)
  return {
    actor = actor,
    blocking = spec.blocking == true,
    sequence = sequence,
    actionIndex = 0,
    actionRepeat = 0,
    destination = { fieldX = position.fieldX, fieldZ = position.fieldZ },
    facing = ctx.services.actors:getFacing(actor),
    facingLocked = false,
    progressTicks = 0,
    durationTicks = 0,
    completed = false,
  }
end

-- The repeat count of one action (walk tiles, on-spot count, delay count).
---@param action table
---@return integer
local function actionCount(action)
  if action.action == "walk" then
    return action.tiles or 1
  end
  return action.count or 1
end

-- Advance one action by one tick. Returns the action's completion flag.
-- The manager owns occupancy and world interpolation; the task drives it
-- through begin/advance/commit and keeps the unit destination in sync.
---@param state table
---@param action table
---@param ctx table
---@return boolean completed
local function advanceAction(state, action, ctx)
  local kind = action.action
  if IMMEDIATE_ACTIONS[kind] then
    if kind == "lock_facing" then
      state.facingLocked = true
    elseif kind == "unlock_facing" then
      state.facingLocked = false
    elseif kind == "set_visible" then
      if action.visible then
        ctx.services.actors:show(state.actor)
      else
        ctx.services.actors:hide(state.actor)
      end
    elseif kind == "pause_animation" then
      ctx.services.actors:setAnimationPaused(state.actor, true)
    elseif kind == "resume_animation" then
      ctx.services.actors:setAnimationPaused(state.actor, false)
    end
    return true
  end
  local isFace = kind == "face"
  local isLocomotion = kind == "walk" or kind == "walk_in_place" or kind == "jump"
  -- Lock facing controls whether the task's internal facing (and the actor
  -- facing applied at action end) follows the command; it does not gate the
  -- test-observable fake facing because the production beginScriptedAction
  -- path covers direction updates for non-locked walks. Move the early
  -- presentation begin before the facing gate so locked faces never touch the
  -- actor.
  local shouldBegin = not isFace or not state.facingLocked
  if state.progressTicks == 0 then
    -- A directional locomotion action's facing is established atomically
    -- before its first presentation is observable: the actor must never show
    -- a walking frame with the previous facing and correct it only once the
    -- action ends. `face` applies its own facing through beginScriptedAction
    -- below (or the fake's commit path); direction lock silences the sprite
    -- facing but never cancels the action's logical displacement vector.
    if isLocomotion and not state.facingLocked and action.direction ~= nil then
      state.facing = action.direction
      ctx.services.actors:setFacing(state.actor, state.facing)
    end
    if shouldBegin then
      ctx.services.actors:beginScriptedAction(state.actor, action)
    end
    if kind == "emote" then
      local effectId = EMOTE_SOUND_CATALOG:effectFor(action.name)
      if effectId ~= nil then
        assert(ctx.services.audio, "an emote with a proven sound mapping requires the audio service"):play(effectId)
      end
    end
  end
  state.progressTicks = state.progressTicks + 1
  if kind == "gesture" then
    local facing = MovementCalibration.gestureFacingAt(action.name, state.progressTicks)
    if facing ~= nil then
      state.facing = facing
      ctx.services.actors:setFacing(state.actor, facing)
    end
  end
  if shouldBegin then
    ctx.services.actors:advanceScriptedAction(state.actor, state.progressTicks, state.durationTicks)
  end
  if state.progressTicks < state.durationTicks then
    return false
  end
  state.progressTicks = 0
  if not state.facingLocked and isFace then
    state.facing = action.direction
  end
  if kind == "walk" or kind == "walk_in_place" then
    if kind == "walk" then
      local delta = DIRECTION_DELTA[action.direction]
      state.destination.fieldX = state.destination.fieldX + delta.fieldX
      state.destination.fieldZ = state.destination.fieldZ + delta.fieldZ
    end
  elseif kind == "jump" then
    if action.distance ~= "zero" then
      local delta = DIRECTION_DELTA[action.direction]
      state.destination.fieldX = state.destination.fieldX + delta.fieldX
      state.destination.fieldZ = state.destination.fieldZ + delta.fieldZ
    end
  elseif kind == "emote" or kind == "gesture" then
    -- pose-only; the renderer consumes the recorded action.
  elseif kind == "delay" then
    -- countdown only
  end
  if shouldBegin then
    ctx.services.actors:commitScriptedAction(state.actor)
  end
  return true
end

-- Advance the plan by one tick. Returns true when the whole sequence
-- completed.
---@param state table
---@param ctx table
---@return boolean done
function MovementTask._advancePlan(state, ctx)
  if state.completed then
    return false
  end
  while true do
    local action = state.sequence[state.actionIndex + 1]
    if action == nil then
      state.completed = true
      return true
    end
    local kind = action.action
    if kind == "unsupported" then
      Errors.raise(
        ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
        "reachable unsupported movement action",
        { scriptId = ctx.instance.scriptId, action = action.originalName or tostring(action.code), code = action.code }
      )
    end
    if state.actionRepeat == 0 and not IMMEDIATE_ACTIONS[kind] then
      state.durationTicks = MovementCalibration.actionTicks(action)
    end
    if advanceAction(state, action, ctx) then
      state.actionRepeat = state.actionRepeat + 1
      if state.actionRepeat >= actionCount(action) then
        state.actionIndex = state.actionIndex + 1
        state.actionRepeat = 0
      end

      -- A completed timed instance is the scheduler's fixed-tick boundary.
      -- Immediate actions may chain on a later poll, but another repetition
      -- or successor action must not become observable in this poll.
      if not IMMEDIATE_ACTIONS[kind] and state.sequence[state.actionIndex + 1] ~= nil then
        return false
      end
    else
      break
    end
  end
  return false
end

---@param state table
---@param ctx table
---@return table
function MovementTask.poll(state, ctx)
  if not state.completed then
    local done = MovementTask._advancePlan(state, ctx)
    if done then
      if state.blocking then
        -- The blocking record completes through the scheduler's poll-result
        -- path; unregister from the movement generation here so barriers
        -- and pause tasks observe the emptied generation in the same poll.
        ctx.environment:unregisterMovementTask(ctx.taskId)
        return { complete = true, state = state, result = { completed = true } }
      end
      ctx.scheduler:completeMovementTask(ctx.taskId, ctx.tick)
    end
  end
  return { complete = false, state = state }
end

function MovementTask.cancel(state, _, ctx)
  if state == nil or ctx == nil or ctx.services == nil or ctx.services.actors == nil then
    return
  end
  local actors = ctx.services.actors
  local ok, err = pcall(function()
    actors:cancelScriptedMovement(state.actor)
  end)
  if not ok and Errors.is(err) then
    error(err, 0)
  end
end

---@param state table
---@return Errors.Error|nil
function MovementTask.validate(state)
  if type(state) ~= "table" or type(state.sequence) ~= "table" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "movement state must hold its sequence",
      { state = state }
    )
  end
  return nil
end

return MovementTask
