-- music_fade task implementation : the blocking
-- translation of FadeOutBGM/FadeInBGM (opcodes 84/85). The task starts the
-- fade in its creation tick (the source command's own execution tick) and
-- blocks until the audio service reports the global music fade inactive,
-- preserving the source command's combined start-and-native-wait semantics
-- (GF_SndStartFadeOutBGM + SetupNativeScript(ScrNative_GetFadeTimer)).
-- Graph continuation follows the generic one-tick handoff. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local MusicFadeTask = {}

MusicFadeTask.type = "music_fade"
MusicFadeTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function MusicFadeTask.create(spec, ctx)
  local node = assert(spec.node, "music fade task requires its graph node")
  assert(node.op == "fade_music_out" or node.op == "fade_music_in", "music fade task requires a fade op")
  local audio = ctx.services.audio
  if audio == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the music fade task requires the audio service",
      { scriptId = ctx.instance.scriptId }
    )
  end
  local audioService = audio --[[@as { fadeMusicOut: fun(self: table, spec: table), fadeMusicIn: fun(self: table, spec: table) }]]
  if node.op == "fade_music_out" then
    audioService:fadeMusicOut(node)
  else
    audioService:fadeMusicIn(node)
  end
  return { op = node.op }
end

---@param state table
---@param ctx table
---@return table
function MusicFadeTask.poll(state, ctx)
  local audio = ctx.services.audio
  if audio == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the music fade task requires the audio service")
  end
  local audioService = audio --[[@as { isMusicFadeActive: fun(self: table): boolean|nil }]]
  local active = audioService:isMusicFadeActive()
  if active == nil then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "the audio service cannot report music fade state")
  end
  if not active then
    return { complete = true, state = state, result = { completed = true } }
  end
  return { complete = false, state = state }
end

---@param state table
---@param reason string
function MusicFadeTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function MusicFadeTask.validate(state)
  if type(state) ~= "table" or state.op == nil then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "music_fade state must hold its op", { state = state })
  end
  return nil
end

return MusicFadeTask
