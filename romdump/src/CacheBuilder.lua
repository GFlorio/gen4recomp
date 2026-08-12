-- Concrete per-version derived-cache build pipeline: compiles every cache
-- class, writes only stale artifacts, emits the machine-readable build-cache
-- log, and returns the build report shape (`{ current = true }` /
-- `nil, err`). Command selection, process exit codes, and love coupling
-- stay in Runner; this module is pure Lua.

local MapAnalysis = require("romdump.src.digest.MapAnalysis")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.MapCacheWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local WorldManifest = require("romdump.src.digest.WorldManifest")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCameraCompiler = require("romdump.src.digest.FieldCameraCompiler")
local FieldCameraCacheWriter = require("romdump.src.digest.FieldCameraCacheWriter")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local FieldMapDataCacheWriter = require("romdump.src.digest.FieldMapDataCacheWriter")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldActorCompiler = require("romdump.src.digest.FieldActorCompiler")
local FieldActorCacheWriter = require("romdump.src.digest.FieldActorCacheWriter")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local FieldMessageCacheWriter = require("romdump.src.digest.FieldMessageCacheWriter")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldFontCompiler = require("romdump.src.digest.FieldFontCompiler")
local FieldFontCacheWriter = require("romdump.src.digest.FieldFontCacheWriter")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ScriptCacheWriter = require("romdump.src.digest.ScriptCacheWriter")
local ScriptCache = require("libs.assets.src.ScriptCache")
local RomFs = require("romdump.src.source.RomFs")
local Errors = require("libs.errors.src.Errors")

local CacheBuilder = {}

-- Compile every supported map into the derived cache for every listed version
-- and emit the world manifest. A map whose cell could not be selected is
-- recorded as `excluded`; a resolved map rejected with a structured compiler
-- error is recorded as `compileExcluded`, writes no partial artifacts, and
-- fails the build unless `allowCompileExclusions` is given. Programming errors
-- still abort the version. A map whose completion marker already matches the
-- current build is left in place, so an unchanged cache rebuilds only what is
-- stale. Every version's RomFs handle is closed exactly once on every path; a
-- failed version is reported and the remaining versions still run.
---@param versionIds string[]
---@param options { allowCompileExclusions?: boolean, log?: fun(line: string) }|nil
---@return table|nil report, string|nil err
function CacheBuilder.buildVersions(versionIds, options)
  options = options or {}
  local log = options.log or print
  if #versionIds == 0 then
    log("build: no ready version to compile")
    return nil, "no ready version to compile"
  end
  local allOk, hasCompileExclusions = true, false
  for _, version in ipairs(versionIds) do
    local romFs
    local ok, err = pcall(function()
      romFs = assert(RomFs.open(version))
      local cacheFs = CacheFs.forVersion(version)
      local cameraBundle = assert(FieldCameraCompiler.compile(romFs))
      if FieldCameraCacheWriter.isReady(cacheFs, cameraBundle.marker) then
        log(string.format("build-cache: %s field cameras current", version))
      else
        FieldCameraCacheWriter.write(cacheFs, cameraBundle)
        log(string.format("build-cache: %s field cameras compiled", version))
      end
      local actorBundle = assert(FieldActorCompiler.compile(romFs))
      if FieldActorCacheWriter.isReady(cacheFs, actorBundle.marker) then
        log(string.format("build-cache: %s field actors current", version))
      else
        FieldActorCacheWriter.write(cacheFs, actorBundle)
        log(string.format("build-cache: %s field actors compiled (%d sprites)", version, #actorBundle.index.spriteIds))
      end
      for _, fieldBundle in ipairs(assert(FieldMapDataCompiler.compileAll(romFs))) do
        if FieldMapDataCache.isReady(cacheFs, fieldBundle.mapId, fieldBundle.marker) then
          log(string.format("build-cache: %s map %d field data current", version, fieldBundle.mapId))
        else
          FieldMapDataCacheWriter.write(cacheFs, fieldBundle)
          log(string.format("build-cache: %s map %d field data compiled", version, fieldBundle.mapId))
        end
      end
      local fontBundle = assert(FieldFontCompiler.compile(romFs))
      if FieldFontCacheWriter.isReady(cacheFs, fontBundle.fontId, fontBundle.marker) then
        log(string.format("build-cache: %s field font current", version))
      else
        FieldFontCacheWriter.write(cacheFs, fontBundle)
        log(string.format("build-cache: %s field font compiled", version))
      end
      local messageBundle = assert(FieldMessageCompiler.compile(romFs))
      if FieldMessageCacheWriter.isReady(cacheFs, messageBundle.marker) then
        log(string.format("build-cache: %s field messages current", version))
      else
        FieldMessageCacheWriter.write(cacheFs, messageBundle)
        log(string.format("build-cache: %s field messages compiled (%d banks)", version, #messageBundle.index.bankIds))
      end
      local scriptBundle = assert(ScriptCompiler.compile(romFs))
      if ScriptCacheWriter.isReady(cacheFs, scriptBundle.marker) then
        log(string.format("build-cache: %s scripts current", version))
      else
        ScriptCacheWriter.write(cacheFs, scriptBundle)
        log(
          string.format(
            "build-cache: %s scripts compiled (%d resources, %d members)",
            version,
            scriptBundle.index.resourceCount,
            scriptBundle.index.scriptMemberCount
          )
        )
      end
      local entries, excluded, compileExcluded = {}, {}, {}
      for _, result in ipairs(MapAnalysis.analyze(romFs)) do
        if result.status == "excluded" then
          excluded[#excluded + 1] = {
            id = result.id,
            symbol = result.symbol,
            reason = result.reason,
            matchCount = result.matchCount,
          }
        else
          local bundle, compileErr = MapAssetCompiler.compile(romFs, result.id)
          if not bundle then
            assert(Errors.is(compileErr), "compiler failure must be a structured error")
            compileErr = compileErr --[[@as Errors.Error]]
            compileExcluded[#compileExcluded + 1] = {
              id = result.id,
              symbol = result.symbol,
              errorCode = compileErr.code,
              message = compileErr.message,
              context = compileErr.context,
            }
            log(string.format("build-cache: %s map %d excluded: %s", version, result.id, Errors.format(compileErr)))
          else
            if MapAssetCache.isReady(cacheFs, bundle.mapId, bundle.marker) then
              log(string.format("build-cache: %s map %d current", version, bundle.mapId))
            else
              MapCacheWriter.write(cacheFs, bundle)
              log(string.format("build-cache: %s map %d compiled", version, bundle.mapId))
            end
            -- Untextured on the DS too, so the map is usable; still reported,
            -- because a mis-routed pack would show up here as a flood.
            for _, entry in ipairs(bundle.unresolvedMaterials) do
              log(
                string.format(
                  "build-cache: %s map %d unresolved %s %s: material %s of %s %s:%d wants %s from %s",
                  version,
                  bundle.mapId,
                  entry.role,
                  entry.kind,
                  entry.material,
                  entry.modelName,
                  entry.modelArchive,
                  entry.modelMemberId,
                  entry.name,
                  entry.source
                )
              )
            end
            entries[#entries + 1] = {
              id = bundle.mapId,
              symbol = bundle.scene.mapSymbol,
              width = bundle.scene.matrix.width,
              height = bundle.scene.matrix.height,
              matrix = {
                memberId = result.matrixMemberId,
                x = result.matrixX,
                z = result.matrixZ,
                index = result.matrixIndex,
                landDataMemberId = result.landDataMemberId,
                selection = result.source,
                matchCount = result.matchCount,
              },
            }
          end
        end
      end
      WorldManifest.write(cacheFs, entries, excluded, compileExcluded)
      log(
        string.format(
          "build-cache: %s world.lua written (%d maps, %d unresolved cells, %d compile-excluded)",
          version,
          #entries,
          #excluded,
          #compileExcluded
        )
      )
      if #compileExcluded > 0 then
        hasCompileExclusions = true
      end
    end)
    if romFs then
      romFs:close()
    end
    if not ok then
      allOk = false
      log("build-cache: " .. version .. " failed: " .. Errors.format(err))
    end
  end
  -- The cache written above is usable, so the scan always finishes; an
  -- unsupported asset still has to be visible to CI, hence the nonzero exit
  -- unless the caller asked for an exploratory run.
  if hasCompileExclusions and not options.allowCompileExclusions then
    log("build-cache: compile exclusions remain; rerun with --allow-compile-exclusions to accept them")
    allOk = false
  end
  if allOk then
    return { current = true }
  end
  return nil, "cache preparation failed"
end

return CacheBuilder
