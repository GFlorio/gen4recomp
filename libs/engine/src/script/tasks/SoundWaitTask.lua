-- sound_wait task implementation : waits for a sound
-- effect, cry, or fanfare through the audio service's semantic completion
-- state. The wait state carries the semantic wait kind: `wait_sound` holds
-- the resolved effect sequence and polls `isEffectPlaying(sequence)`;
-- `wait_cry` polls `isCryFinished`; `wait_fanfare` polls
-- `isFanfarePlaying`. A backend that cannot report completion for the kind
-- is a fault, never a simulated duration. Graph continuation follows the
-- generic one-tick handoff. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local Runtime = require("libs.engine.src.script.Runtime")

local SoundWaitTask = {}

SoundWaitTask.type = "sound_wait"
-- Serialized-state shape: kind + resolved sequence (was token strings).
SoundWaitTask.version = 2

---@param spec table
---@param ctx table
---@return table state
function SoundWaitTask.create(spec, ctx)
  local node = spec.node or {}
  local audio = ctx.services.audio
  if audio == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the sound wait task requires the audio service",
      { scriptId = ctx.instance.scriptId }
    )
  end
  local kind = "effect"
  if node.op == "wait_cry" then
    kind = "cry"
  elseif node.op == "wait_fanfare" then
    kind = "fanfare"
  end
  if kind == "cry" then
    local audioService = audio --[[@as { isCryFinished: fun(self: table): boolean|nil }]]
    if type(audioService.isCryFinished) ~= "function" then
      Errors.raise(
        ScriptErrors.SCRIPT_SERVICE_MISSING,
        "the audio service must report isCryFinished for wait_cry",
        { scriptId = ctx.instance.scriptId }
      )
    end
    return { kind = "cry" }
  end
  if kind == "fanfare" then
    local audioService = audio --[[@as { isFanfarePlaying: fun(self: table): boolean|nil }]]
    if type(audioService.isFanfarePlaying) ~= "function" then
      Errors.raise(
        ScriptErrors.SCRIPT_SERVICE_MISSING,
        "the audio service must report isFanfarePlaying for wait_fanfare",
        { scriptId = ctx.instance.scriptId }
      )
    end
    return { kind = "fanfare" }
  end
  -- The effect wait carries the resolved sequence: HGSS WaitSE always reads
  -- an explicit operand (scrcmd_sound.c ScrCmd_WaitSE via ScriptGetVar),
  -- the lowering always emits one, and the schema requires it -- an
  -- operand-less wait is not a valid producer shape and faults.
  local sequence = node.sound
  if sequence == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "the effect wait has no completion sequence",
      { scriptId = ctx.instance.scriptId }
    )
  end
  sequence = Runtime.evaluateValue(sequence, { services = ctx.services, instance = ctx.instance })
  if sequence == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "the effect wait has no completion sequence",
      { scriptId = ctx.instance.scriptId }
    )
  end
  local audioService = audio --[[@as { isEffectPlaying: fun(self: table, sequence: any): boolean|nil }]]
  if type(audioService.isEffectPlaying) ~= "function" then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the audio service must report effect play state for sound waits",
      { scriptId = ctx.instance.scriptId }
    )
  end
  return {
    kind = "effect",
    sequence = sequence,
  }
end

---@param state table
---@param ctx table
---@return table
function SoundWaitTask.poll(state, ctx)
  local audio = ctx.services.audio
  if audio == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the sound wait task requires the audio service")
  end
  local done
  if state.kind == "effect" then
    local audioService = audio --[[@as { isEffectPlaying: fun(self: table, sequence: any): boolean|nil }]]
    local playing = audioService:isEffectPlaying(state.sequence)
    if playing == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "the audio service cannot report completion for the effect wait",
        { kind = state.kind, sequence = state.sequence }
      )
    end
    done = not playing
  elseif state.kind == "cry" then
    local audioService = audio --[[@as { isCryFinished: fun(self: table): boolean|nil }]]
    local finished = audioService:isCryFinished()
    if finished == nil then
      Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "the audio service cannot report cry completion", {
        kind = state.kind,
      })
    end
    done = finished
  else
    local audioService = audio --[[@as { isFanfarePlaying: fun(self: table): boolean|nil }]]
    local playing = audioService:isFanfarePlaying()
    if playing == nil then
      Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "the audio service cannot report fanfare completion", {
        kind = state.kind,
      })
    end
    done = not playing
  end
  if done then
    return { complete = true, state = state, result = { completed = true } }
  end
  return { complete = false, state = state }
end

---@param state table
---@param reason string
function SoundWaitTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function SoundWaitTask.validate(state)
  if type(state) ~= "table" or state.kind == nil then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "sound_wait state must hold its kind", { state = state })
  end
  if state.kind ~= "effect" and state.kind ~= "cry" and state.kind ~= "fanfare" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "sound_wait state holds an unknown kind", {
      state = state,
    })
  end
  if state.kind == "effect" and state.sequence == nil then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "effect wait state must hold its resolved sequence",
      { state = state }
    )
  end
  return nil
end

return SoundWaitTask
