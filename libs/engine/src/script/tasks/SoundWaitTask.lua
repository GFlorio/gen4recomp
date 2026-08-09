-- sound_wait task implementation : waits for a named sound, cry, or fanfare through the
-- audio backend when one can report completion, otherwise falls back to a
-- documented catalog duration and completes deterministically with a
-- diagnostic. Graph continuation follows the generic one-tick handoff. Pure
-- domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local SoundWaitTask = {}

SoundWaitTask.type = "sound_wait"
SoundWaitTask.version = 1

-- Catalog fallback duration (headless or non-completing backends). Recorded
-- decision for a full SE/cry/fanfare plays for 20 ticks at
-- 30 Hz; backends that report completion take precedence.
SoundWaitTask.FALLBACK_TICKS = 20

---@param spec table
---@param ctx table
---@return table state
function SoundWaitTask.create(spec, ctx)
  local node = spec.node or {}
  local audio = ctx.services.audio
  local kind = "sound"
  if node.op == "wait_cry" then
    kind = "cry"
  elseif node.op == "wait_fanfare" then
    kind = "fanfare"
  end
  local sound = node.sound
  if sound == nil and kind == "sound" and audio ~= nil and audio.currentEffect then
    sound = audio:currentEffect()
  end
  return {
    kind = kind,
    sound = sound,
    fallbackTicks = nil,
  }
end

---@param state table
---@param ctx table
---@return table
function SoundWaitTask.poll(state, ctx)
  local audio = ctx.services.audio
  if audio ~= nil and audio.isPlaying ~= nil then
    local playing = audio:isPlaying(state.sound)
    if playing ~= nil then
      if playing == false then
        return { complete = true, state = state, result = { completed = true } }
      end
      return { complete = false, state = state }
    end
  end
  -- Deterministic fallback: the backend cannot report completion.
  if state.fallbackTicks == nil then
    state.fallbackTicks = SoundWaitTask.FALLBACK_TICKS
  end
  state.fallbackTicks = state.fallbackTicks - 1
  if state.fallbackTicks <= 0 then
    return {
      complete = true,
      state = state,
      result = {
        completed = true,
        fallback = true,
        diagnostic = "audio backend cannot report completion; used catalog duration",
      },
    }
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
