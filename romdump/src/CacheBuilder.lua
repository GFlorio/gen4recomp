-- Concrete per-version derived-cache build pipeline: compiles every cache
-- class, writes only stale artifacts, emits the machine-readable build-cache
-- log, and returns the build report (`{ published = true, complete = ...,
-- exclusionCount = ... }` / `nil, err`). Command selection, process exit
-- codes, and love coupling stay in Runner; this module is pure Lua.

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
local FieldFontCompiler = require("romdump.src.digest.FieldFontCompiler")
local FieldFontCacheWriter = require("romdump.src.digest.FieldFontCacheWriter")
local FieldUiCompiler = require("romdump.src.digest.FieldUiCompiler")
local FieldUiCacheWriter = require("romdump.src.digest.FieldUiCacheWriter")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ScriptCacheWriter = require("romdump.src.digest.ScriptCacheWriter")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCacheWriter = require("romdump.src.digest.AudioCacheWriter")
local RomFs = require("romdump.src.source.RomFs")
local Errors = require("libs.errors.src.Errors")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local RawDumpContract = require("romdump.src.source.RawDumpContract")
local ScriptDsl = require("gen4.script")

local CacheBuilder = {}

-- Convert one source-data stage's `nil, err` (RomFs.open or a compiler) into
-- the version body's expected-failure return. The stages contract a structured
-- error; anything else is a programming fault and raises here.
local function versionFailure(err)
  assert(Errors.is(err), "source-data stage failure must be a structured error")
  return nil, err
end

-- Compile every supported map into the derived cache for every listed version
-- and emit the world manifest. A map whose cell could not be selected is
-- recorded as `excluded`; a resolved map rejected with a structured compiler
-- error is recorded as `compileExcluded`, writes no partial artifacts, and
-- fails the build unless `allowCompileExclusions` is given. A map whose
-- completion marker already matches the current build is left in place, so an
-- unchanged cache rebuilds only what is stale.
--
-- For each version the build identity (dump marker + producer fingerprint +
-- asset contract + script DSL API) is compared against the stored
-- successful-build attestation first, before any RomFs open: a matching
-- identity whose availability audit passes reports the version current
-- without opening the ROM or calling any compiler, and a matching identity
-- whose audit fails enters the incremental repair path. A differing identity
-- forces every class to regenerate regardless of its marker checks.
--
-- The world manifest is staged per version but published only after the whole
-- batch has reached the success level required for the authoritative index: a
-- failed version or an unaccepted exclusion leaves every staged manifest
-- discarded and the previous live world.lua untouched, so a later build
-- failure can never install a new partial world. The successful-build
-- attestation publishes at the same point (per strict version, never before
-- the world it vouches for), so a stale world index can never fast-path as
-- current.
--
-- Expected per-version failures are the structured errors the source-data
-- stage boundaries (RomFs.open and the compilers) return as `nil, err`; they
-- mean this version's dump is corrupted, malformed, or unsupported, so the
-- version is reported and the batch continues. Nothing else is recoverable at
-- the batch boundary: programming faults and structured errors that are raised
-- directly (cache write failures, duplicate world-manifest ids) indicate a
-- broken invariant and propagate after the version's RomFs has been closed.
--
-- The returned report distinguishes a complete strict build from an explicitly
-- accepted partial build: `published` is true whenever the authoritative world
-- index is in place for the outcome (newly staged worlds were published; a
-- fast-path build found them already current), `complete` is false exactly
-- when compile exclusions were present, and `exclusionCount` totals the
-- compile-excluded maps across every version.
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
  local producerFingerprint = ProducerFingerprint.compute(ProducerFingerprint.appBackend())
  local allOk, hasCompileExclusions, exclusionCount = true, false, 0
  local stagedWorlds = {}
  local strictVersions = {}
  local function discardStagedWorlds()
    for _, world in ipairs(stagedWorlds) do
      world:abort()
    end
  end
  for _, version in ipairs(versionIds) do
    local romFs
    local ok, result, failureErr = pcall(function()
      local cacheFs = CacheFs.forVersion(version)
      local dumpMarker = cacheFs:read(RawDumpContract.MARKER_PATH)
      assert(type(dumpMarker) == "string", "a ready version must have a published dump marker")
      local identity = DerivedCacheState.current({
        dump = dumpMarker,
        producer = producerFingerprint,
        assetContract = DerivedAssetContract,
        scriptApi = ScriptDsl.apiVersion,
      })
      local forced = false
      if DerivedCacheState.matches(cacheFs:loadLua(DerivedCacheState.path), identity) then
        if DerivedCacheAudit.isAvailable(cacheFs) then
          log(string.format("build-cache: %s current", version))
          return true
        end
      else
        forced = true
      end
      DerivedCacheState.invalidate(cacheFs)
      local opened, openErr = RomFs.open(version)
      if not opened then
        return versionFailure(openErr)
      end
      romFs = opened
      local cameraBundle, cameraErr = FieldCameraCompiler.compile(romFs)
      if not cameraBundle then
        return versionFailure(cameraErr)
      end
      if forced or not FieldCameraCacheWriter.isReady(cacheFs, cameraBundle.marker) then
        FieldCameraCacheWriter.write(cacheFs, cameraBundle)
        log(string.format("build-cache: %s field cameras compiled", version))
      else
        log(string.format("build-cache: %s field cameras current", version))
      end
      local actorBundle, actorErr = FieldActorCompiler.compile(romFs)
      if not actorBundle then
        return versionFailure(actorErr)
      end
      if forced or not FieldActorCacheWriter.isReady(cacheFs, actorBundle.marker) then
        FieldActorCacheWriter.write(cacheFs, actorBundle)
        log(string.format("build-cache: %s field actors compiled (%d sprites)", version, #actorBundle.index.spriteIds))
      else
        log(string.format("build-cache: %s field actors current", version))
      end
      local fieldBundles, fieldErr = FieldMapDataCompiler.compileAll(romFs)
      if not fieldBundles then
        return versionFailure(fieldErr)
      end
      for _, fieldBundle in ipairs(fieldBundles) do
        if forced or not FieldMapDataCache.isReady(cacheFs, fieldBundle.mapId, fieldBundle.marker) then
          FieldMapDataCacheWriter.write(cacheFs, fieldBundle)
          log(string.format("build-cache: %s map %d field data compiled", version, fieldBundle.mapId))
        else
          log(string.format("build-cache: %s map %d field data current", version, fieldBundle.mapId))
        end
      end
      local fontBundle, fontErr = FieldFontCompiler.compile(romFs)
      if not fontBundle then
        return versionFailure(fontErr)
      end
      if forced or not FieldFontCacheWriter.isReady(cacheFs, fontBundle.fontId, fontBundle.marker) then
        FieldFontCacheWriter.write(cacheFs, fontBundle)
        log(string.format("build-cache: %s field font compiled", version))
      else
        log(string.format("build-cache: %s field font current", version))
      end
      local uiBundle, uiErr = FieldUiCompiler.compile(romFs)
      if not uiBundle then
        return versionFailure(uiErr)
      end
      if forced or not FieldUiCacheWriter.isReady(cacheFs, uiBundle.marker) then
        FieldUiCacheWriter.write(cacheFs, uiBundle)
        log(string.format("build-cache: %s field ui compiled", version))
      else
        log(string.format("build-cache: %s field ui current", version))
      end
      local messageBundle, messageErr = FieldMessageCompiler.compile(romFs)
      if not messageBundle then
        return versionFailure(messageErr)
      end
      if forced or not FieldMessageCacheWriter.isReady(cacheFs, messageBundle.marker) then
        FieldMessageCacheWriter.write(cacheFs, messageBundle)
        log(string.format("build-cache: %s field messages compiled (%d banks)", version, #messageBundle.index.bankIds))
      else
        log(string.format("build-cache: %s field messages current", version))
      end
      local scriptBundle, scriptErr = ScriptCompiler.compile(romFs)
      if not scriptBundle then
        return versionFailure(scriptErr)
      end
      if forced or not ScriptCacheWriter.isReady(cacheFs, scriptBundle.marker) then
        ScriptCacheWriter.write(cacheFs, scriptBundle)
        log(
          string.format(
            "build-cache: %s scripts compiled (%d resources, %d members)",
            version,
            scriptBundle.index.resourceCount,
            scriptBundle.index.scriptMemberCount
          )
        )
      else
        log(string.format("build-cache: %s scripts current", version))
      end
      local audioBundle, audioErr = AudioCompiler.compile(romFs)
      if not audioBundle then
        return versionFailure(audioErr)
      end
      if forced or not AudioCacheWriter.isReady(cacheFs, audioBundle.marker) then
        AudioCacheWriter.write(cacheFs, audioBundle)
        log(string.format("build-cache: %s audio compiled", version))
      else
        log(string.format("build-cache: %s audio current", version))
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
            if forced or not MapAssetCache.isReady(cacheFs, bundle.mapId, bundle.marker) then
              MapCacheWriter.write(cacheFs, bundle)
              log(string.format("build-cache: %s map %d compiled", version, bundle.mapId))
            else
              log(string.format("build-cache: %s map %d current", version, bundle.mapId))
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
      local world = WorldManifest.stage(cacheFs, entries, excluded, compileExcluded)
      stagedWorlds[#stagedWorlds + 1] = world
      log(
        string.format(
          "build-cache: %s world.lua staged (%d maps, %d unresolved cells, %d compile-excluded)",
          version,
          #entries,
          #excluded,
          #compileExcluded
        )
      )
      if #compileExcluded > 0 then
        hasCompileExclusions = true
        exclusionCount = exclusionCount + #compileExcluded
      else
        strictVersions[#strictVersions + 1] = { cacheFs = cacheFs, identity = identity }
      end
      return true
    end)
    if romFs then
      romFs:close()
    end
    if not ok then
      discardStagedWorlds()
      error(result, 0)
    end
    if result == nil then
      allOk = false
      log("build-cache: " .. version .. " failed: " .. Errors.format(failureErr))
    end
  end
  -- The cache written above is usable, so the scan always finishes; an
  -- unsupported asset still has to be visible to CI, hence the nonzero exit
  -- unless the caller asked for an exploratory run. Only a successful batch
  -- (no failed version, no unaccepted exclusion) publishes the staged worlds
  -- and the successful-build attestations: a failed batch discards every
  -- staged manifest, so the previous live world.lua stays authoritative.
  if hasCompileExclusions and not options.allowCompileExclusions then
    log("build-cache: compile exclusions remain; rerun with --allow-compile-exclusions to accept them")
    allOk = false
  end
  if not allOk then
    discardStagedWorlds()
    return nil, "cache preparation failed"
  end
  for _, world in ipairs(stagedWorlds) do
    world:publish()
    log("build-cache: " .. world.version .. " world.lua published")
  end
  for _, strict in ipairs(strictVersions) do
    DerivedCacheState.publish(strict.cacheFs, strict.identity)
  end
  return {
    published = true,
    complete = not hasCompileExclusions,
    exclusionCount = exclusionCount,
  }
end

return CacheBuilder
