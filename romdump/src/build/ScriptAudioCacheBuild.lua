-- Builds script and audio derived assets for one version.

local Errors = require("libs.errors.src.Errors")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")

local ScriptAudioCacheBuild = {}

---@param bundle table<string, unknown>|nil
---@param err Errors.Error|string|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
local function requireBundle(bundle, err)
  if bundle then
    return bundle
  end
  assert(Errors.is(err), "script/audio stage failure must be a structured error")
  return nil, err
end

---@param context VersionBuildContext
---@return true|nil, Errors.Error|string|nil
function ScriptAudioCacheBuild.build(context)
  local bundle, err = ScriptCompiler.compile(context.romFs)
  local script = requireBundle(bundle, err)
  if not script then
    return nil, err
  end
  if context.forced or not ScriptCacheWriter.isReady(context.cacheFs, script.marker) then
    ScriptCacheWriter.write(context.cacheFs, script)
    context.log(
      string.format(
        "build-cache: %s scripts compiled (%d resources, %d members)",
        context.version,
        script.index.resourceCount,
        script.index.scriptMemberCount
      )
    )
  else
    context.log(string.format("build-cache: %s scripts current", context.version))
  end

  local audioBundle, audioErr = AudioCompiler.compile(context.romFs)
  local audio = requireBundle(audioBundle, audioErr)
  if not audio then
    return nil, err
  end
  if context.forced or not AudioCacheWriter.isReady(context.cacheFs, audio.marker) then
    AudioCacheWriter.write(context.cacheFs, audio)
    context.log(string.format("build-cache: %s audio compiled", context.version))
  else
    context.log(string.format("build-cache: %s audio current", context.version))
  end
  return true
end

return ScriptAudioCacheBuild
