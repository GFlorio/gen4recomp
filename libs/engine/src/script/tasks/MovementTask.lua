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

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local MovementCalibration = require("libs.engine.src.script.tasks.MovementCalibration")

local MovementTask = {}

MovementTask.type = "movement"
MovementTask.version = 1

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
  state.progressTicks = state.progressTicks + 1
  if state.progressTicks < state.durationTicks then
    return false
  end
  state.progressTicks = 0
  if not state.facingLocked then
    if kind == "face" or kind == "walk" or kind == "walk_in_place" or kind == "jump" then
      state.facing = action.direction
    end
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
    else
      break
    end
  end
  return false
end

-- Apply the actor's current position and facing through the actor world.
---@param state table
---@param ctx table
local function applyPosition(state, ctx)
  ctx.services.actors:setPosition(state.actor, {
    fieldX = state.destination.fieldX,
    fieldZ = state.destination.fieldZ,
    worldY = nil,
  })
  if state.facing ~= nil and not state.facingLocked then
    ctx.services.actors:setFacing(state.actor, state.facing)
  end
end

---@param state table
---@param ctx table
---@return table
function MovementTask.poll(state, ctx)
  if not state.completed then
    local done = MovementTask._advancePlan(state, ctx)
    applyPosition(state, ctx)
    if done and not state.blocking then
      ctx.scheduler:completeMovementTask(ctx.taskId, ctx.tick)
    end
    if done and state.blocking then
      return { complete = true, state = state, result = { completed = true } }
    end
  end
  return { complete = false, state = state }
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
