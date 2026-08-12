-- The test-runner cache probe accepts fully published artifacts and rejects a
-- partial cache without invoking the expensive source compilers.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")

local T = {}

local function publishedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, path in ipairs({
    FieldActorCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    FieldMessageCache.markerPath(),
    ScriptCache.markerPath(),
    MapAssetCache.mapDir(7) .. "/complete",
    FieldMapDataCache.markerPath(7),
  }) do
    cache:write(path, "complete")
  end
  cache:writeLua(ScriptCache.provenancePath(), {
    schema = ScriptCache.PROVENANCE_SCHEMA,
    dependencies = { compilerVersion = ScriptCompiler.COMPILER_VERSION },
  })
  cache:writeLua(MapAssetCache.worldPath(), { maps = { { id = 7 } } })
  return cache
end

function T.published_artifacts_are_available_without_recompiling()
  Assert.isTrue(DerivedCacheAudit.isAvailable(publishedCache()))
end

function T.a_missing_published_artifact_requires_a_build()
  local cache = publishedCache()
  cache:remove(ScriptCache.markerPath())

  local available, reason = DerivedCacheAudit.isAvailable(cache)

  Assert.isFalse(available)
  Assert.equal(reason, "missing completion marker " .. ScriptCache.markerPath())
end

function T.a_script_cache_from_an_older_compiler_requires_a_build()
  local cache = publishedCache()
  cache:writeLua(ScriptCache.provenancePath(), {
    schema = ScriptCache.PROVENANCE_SCHEMA,
    dependencies = { compilerVersion = "script-compiler-v0" },
  })

  local available, reason = DerivedCacheAudit.isAvailable(cache)

  Assert.isFalse(available)
  Assert.equal(reason, "script cache compiler is not " .. ScriptCompiler.COMPILER_VERSION)
end

return T
