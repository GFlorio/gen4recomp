-- sound_wait task implementation : waits for a named sound,
-- cry, or fanfare through the audio backend. Every wait carries a concrete
-- completion token: `wait_sound` infers the current effect from the backend,
-- while `wait_cry` and `wait_fanfare` name their own token; a backend that
-- cannot report completion for the token is a fault, never a simulated
-- duration. Graph continuation follows the generic one-tick handoff. Pure
-- domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local SoundWaitTask = {}

SoundWaitTask.type = "sound_wait"
SoundWaitTask.version = 1

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
  local kind = "sound"
  local tokenReader = "currentEffect"
  if node.op == "wait_cry" then
    kind = "cry"
    tokenReader = "currentCry"
  elseif node.op == "wait_fanfare" then
    kind = "fanfare"
    tokenReader = "currentFanfare"
  end
  local sound = node.sound
  if sound == nil then
    -- The wait names no token of its own: it waits for whatever effect,
    -- cry, or fanfare is currently playing, resolved through the backend.
    local audioService = audio --[[@as { currentEffect: fun(self: table): string|nil, currentCry: fun(self: table): string|nil, currentFanfare: fun(self: table): string|nil, isPlaying: fun(self: table, sound: string): boolean|nil }]]
    if type(audioService[tokenReader]) ~= "function" then
      Errors.raise(
        ScriptErrors.SCRIPT_SERVICE_MISSING,
        "the audio service must identify the current " .. kind .. " for wait_" .. (kind == "sound" and "sound" or kind),
        { scriptId = ctx.instance.scriptId }
      )
    end
    sound = audioService[tokenReader](audioService)
  end
  if sound == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "the " .. kind .. " wait has no completion token",
      { scriptId = ctx.instance.scriptId }
    )
  end
  local audioService = audio --[[@as { isPlaying: fun(self: table, sound: string): boolean|nil }]]
  if type(audioService.isPlaying) ~= "function" then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the audio service must report play state for sound waits",
      { scriptId = ctx.instance.scriptId }
    )
  end
  return {
    kind = kind,
    sound = sound,
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
  local audioService = audio --[[@as { isPlaying: fun(self: table, sound: string): boolean|nil }]]
  local playing = audioService:isPlaying(state.sound)
  if playing == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "the audio service cannot report completion for " .. tostring(state.sound),
      { kind = state.kind, sound = state.sound }
    )
  end
  if playing == false then
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
  return nil
end

return SoundWaitTask
