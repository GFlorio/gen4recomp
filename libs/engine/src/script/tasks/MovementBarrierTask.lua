-- movement_barrier task implementation : the
-- native-style wait over the execution environment's movement generation. An
-- environment-scoped barrier watches the generation predicate (movements
-- launched into the same generation after the barrier was created are
-- included), and an actor-scoped barrier freezes the exact movement task ids
-- of its actors at creation (each actor reference resolves through the actor
-- world at creation, matching the compiled actor-ref tables). Even an empty
-- barrier first polls on the next tick and hands off one tick after the
-- successful poll. On completion the environment advances to the next
-- movement generation before any context runs in that tick. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local Runtime = require("libs.engine.src.script.Runtime")

local MovementBarrierTask = {}

MovementBarrierTask.type = "movement_barrier"
MovementBarrierTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function MovementBarrierTask.create(spec, ctx)
  local node = spec.node or {}
  local scope = node.scope or "environment"
  local state = { scope = scope, taskIds = nil }
  if scope == "actors" then
    -- Resolve every actor reference through the actor world (compiled
    -- scripts carry actor-ref tables, handwritten scripts may pass plain
    -- ids) and freeze the matching movement task ids at creation.
    local run = {
      instance = ctx.instance,
      services = ctx.services,
      environment = ctx.environment,
    }
    local actors = {}
    for _, actor in ipairs(node.actors or {}) do
      actors[#actors + 1] = Runtime.resolveActor(actor, run)
    end
    local taskIds = {}
    local environment = ctx.environment
    for _, taskId in ipairs(environment:movementTasksInGeneration(environment:currentGeneration())) do
      local task = ctx.scheduler:taskById(taskId)
      if task ~= nil and task.state ~= nil and task.state.actor ~= nil then
        for _, actor in ipairs(actors) do
          if task.state.actor == actor then
            taskIds[#taskIds + 1] = taskId
          end
        end
      end
    end
    state.taskIds = taskIds
  elseif scope ~= "environment" then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "unknown movement barrier scope",
      { scope = scope, scriptId = ctx.instance.scriptId }
    )
  end
  return state
end

---@param state table
---@param ctx table
---@return table
function MovementBarrierTask.poll(state, ctx)
  local done
  if state.scope == "environment" then
    done = not ctx.environment:hasOutstandingMovement()
  else
    done = true
    for _, taskId in ipairs(state.taskIds) do
      local task = ctx.scheduler:taskById(taskId)
      if task == nil or task.status ~= "completed" then
        done = false
        break
      end
    end
  end
  if done then
    return { complete = true, state = state, result = { scope = state.scope } }
  end
  return { complete = false, state = state }
end

-- The environment advances to the next movement generation when the barrier
-- completes during task polling, so movements launched later in the same
-- tick belong to the new generation.
---@param state table
---@param ctx table
function MovementBarrierTask.onComplete(state, ctx)
  if state.scope == "environment" then
    ctx.environment:advanceMovementGeneration()
  end
end

---@param state table
---@param reason string
function MovementBarrierTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function MovementBarrierTask.validate(state)
  if type(state) ~= "table" or (state.scope ~= "environment" and state.scope ~= "actors") then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "movement barrier state must hold its scope", context)
  end
  if state.scope == "actors" and type(state.taskIds) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "actor-scoped movement barrier state must hold its task id list",
      context
    )
  end
  return nil
end

return MovementBarrierTask
