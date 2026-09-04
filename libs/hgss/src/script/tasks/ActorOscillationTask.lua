-- Blocking actor oscillation: reproduces ScrCmd_523 render-vector oscillation.
-- The task owns serializable presentation math: cycles, angle, step, amplitudes.
-- Each poll applies sin(angle)*amplitude to X/Z, then increments angle; when
-- angle >=360 it resets to 0 and decrements remaining cycles; when cycles
-- reach 0 it clears the offset and completes. No world/occupancy mutation.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local ActorOscillationTask = {}

ActorOscillationTask.type = "actor_oscillation"
ActorOscillationTask.version = 1

local function isFiniteNumber(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function validateFields(state)
  if type(state) ~= "table" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "actor oscillation state must be a table",
      { state = state }
    )
  end
  if type(state.actor) ~= "string" or state.actor == "" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "actor oscillation state requires an actor",
      { state = state }
    )
  end
  if type(state.remainingCycles) ~= "number" or state.remainingCycles % 1 ~= 0 or state.remainingCycles <= 0 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "cycles must be a positive integer", { state = state })
  end
  if type(state.angle) ~= "number" or state.angle < 0 or state.angle >= 360 then
    -- angle is 0..359 inclusive, but during validation we allow 0 <= angle <360
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "angle must be in [0,360)", { state = state })
  end
  if type(state.degreesPerTick) ~= "number" or state.degreesPerTick % 1 ~= 0 or state.degreesPerTick <= 0 then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "degreesPerTick must be a positive integer",
      { state = state }
    )
  end
  if not isFiniteNumber(state.amplitudeX) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "amplitudeX must be finite", { state = state })
  end
  if not isFiniteNumber(state.amplitudeZ) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "amplitudeZ must be finite", { state = state })
  end
  return nil
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function ActorOscillationTask.create(spec, ctx)
  local actor = spec.actor
  assert(actor ~= nil, "actor oscillation task requires an actor")
  local cycles = spec.cycles
  local degreesPerTick = spec.degreesPerTick
  local amplitudeX = spec.amplitudeX
  local amplitudeZ = spec.amplitudeZ
  if cycles == nil or degreesPerTick == nil or amplitudeX == nil or amplitudeZ == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "actor oscillation task requires cycles, degreesPerTick, amplitudes",
      {
        scriptId = ctx and ctx.instance and ctx.instance.scriptId or nil,
      }
    )
  end
  if type(cycles) ~= "number" or cycles % 1 ~= 0 or cycles <= 0 then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "cycles must be a positive integer", {
      scriptId = ctx and ctx.instance and ctx.instance.scriptId or nil,
      cycles = cycles,
    })
  end
  if type(degreesPerTick) ~= "number" or degreesPerTick % 1 ~= 0 or degreesPerTick <= 0 then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "degreesPerTick must be a positive integer", {
      scriptId = ctx and ctx.instance and ctx.instance.scriptId or nil,
      degreesPerTick = degreesPerTick,
    })
  end
  if not isFiniteNumber(amplitudeX) or not isFiniteNumber(amplitudeZ) then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "amplitudes must be finite", {
      scriptId = ctx and ctx.instance and ctx.instance.scriptId or nil,
      amplitudeX = amplitudeX,
      amplitudeZ = amplitudeZ,
    })
  end
  return {
    actor = actor,
    remainingCycles = cycles,
    angle = 0,
    degreesPerTick = degreesPerTick,
    amplitudeX = amplitudeX,
    amplitudeZ = amplitudeZ,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function ActorOscillationTask.poll(state, ctx)
  local actors = assert(ctx.services.actors, "actor oscillation task requires the actor service")
  -- Apply current angle offset before increment, matching source order.
  local offsetFactor = math.sin(math.rad(state.angle))
  actors:setPresentationOffset(state.actor, {
    x = offsetFactor * state.amplitudeX,
    y = 0,
    z = offsetFactor * state.amplitudeZ,
  })
  state.angle = state.angle + state.degreesPerTick
  if state.angle >= 360 then
    state.angle = 0
    state.remainingCycles = state.remainingCycles - 1
  end
  if state.remainingCycles == 0 then
    -- Terminal zero write and complete on same poll.
    actors:clearPresentationOffset(state.actor)
    return { complete = true, state = state, result = { completed = true } }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function ActorOscillationTask.cancel(state, reason, ctx)
  if state == nil then
    return
  end
  if ctx == nil or ctx.services == nil or ctx.services.actors == nil then
    return
  end
  local actors = ctx.services.actors
  actors:clearPresentationOffset(state.actor)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function ActorOscillationTask.validate(state)
  return validateFields(state)
end

return ActorOscillationTask
