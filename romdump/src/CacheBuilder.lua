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
local FieldWeatherCompiler = require("romdump.src.digest.FieldWeatherCompiler")
local FieldWeatherCacheWriter = require("romdump.src.digest.FieldWeatherCacheWriter")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.FieldEntranceIndicatorCompiler")
local FieldEntranceIndicatorCacheWriter = require("romdump.src.digest.FieldEntranceIndicatorCacheWriter")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local BindingCompiler = require("romdump.src.digest.script.BindingCompiler")
local ScriptCacheWriter = require("romdump.src.digest.ScriptCacheWriter")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCacheWriter = require("romdump.src.digest.AudioCacheWriter")
local FieldCellCompiler = require("romdump.src.digest.FieldCellCompiler")
local FieldCellCacheWriter = require("romdump.src.digest.FieldCellCacheWriter")
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
---@param err Errors.Error|nil
---@return nil
---@return Errors.Error
local function versionFailure(err)
  assert(Errors.is(err), "source-data stage failure must be a structured error")
  ---@cast err Errors.Error
  return nil, err
end

---@param version string
---@param log fun(line: string)
---@param producerFingerprint string
---@param stagedWorlds table[]
---@param strictVersions table[]
---@return table
local function newVersionContext(version, log, producerFingerprint, stagedWorlds, strictVersions)
  return {
    version = version,
    log = log,
    producerFingerprint = producerFingerprint,
    stagedWorlds = stagedWorlds,
    strictVersions = strictVersions,
    cacheFs = nil,
    identity = nil,
    forced = false,
    romFs = nil,
    hasCompileExclusions = false,
    exclusionCount = 0,
  }
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function prepareVersion(context)
  local cacheFs = CacheFs.forVersion(context.version)
  context.cacheFs = cacheFs
  local dumpMarker = cacheFs:read(RawDumpContract.MARKER_PATH)
  assert(type(dumpMarker) == "string", "a ready version must have a published dump marker")
  local identity = DerivedCacheState.current({
    dump = dumpMarker,
    producer = context.producerFingerprint,
    assetContract = DerivedAssetContract,
    scriptApi = ScriptDsl.apiVersion,
  })
  context.identity = identity
  if DerivedCacheState.matches(cacheFs:loadLua(DerivedCacheState.path), identity) then
    if DerivedCacheAudit.isAvailable(cacheFs) then
      context.log(string.format("build-cache: %s current", context.version))
      return false
    end
  else
    context.forced = true
  end
  DerivedCacheState.invalidate(cacheFs)
  local opened, openErr = RomFs.open(context.version)
  if not opened then
    return versionFailure(openErr --[[@as Errors.Error]])
  end
  context.romFs = opened
  return true
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildFieldCameras(context)
  local bundle, err = FieldCameraCompiler.compile(context.romFs)
  if not bundle then
    return versionFailure(err)
  end
  if context.forced or not FieldCameraCacheWriter.isReady(context.cacheFs, bundle.marker) then
    FieldCameraCacheWriter.write(context.cacheFs, bundle)
    context.log(string.format("build-cache: %s field cameras compiled", context.version))
  else
    context.log(string.format("build-cache: %s field cameras current", context.version))
  end
  return true
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildFieldActors(context)
  local bundle, err = FieldActorCompiler.compile(context.romFs)
  if not bundle then
    return versionFailure(err)
  end
  if context.forced or not FieldActorCacheWriter.isReady(context.cacheFs, bundle.marker) then
    FieldActorCacheWriter.write(context.cacheFs, bundle)
    context.log(
      string.format("build-cache: %s field actors compiled (%d sprites)", context.version, #bundle.index.spriteIds)
    )
  else
    context.log(string.format("build-cache: %s field actors current", context.version))
  end
  return true
end

---@param context table
---@return table[]|nil
---@return Errors.Error|nil
local function buildFieldData(context)
  local bundles, err = FieldMapDataCompiler.compileAll(context.romFs)
  if not bundles then
    return versionFailure(err)
  end
  for _, bundle in ipairs(bundles) do
    if context.forced or not FieldMapDataCache.isReady(context.cacheFs, bundle.mapId, bundle.marker) then
      FieldMapDataCacheWriter.write(context.cacheFs, bundle)
      context.log(string.format("build-cache: %s map %d field data compiled", context.version, bundle.mapId))
    else
      context.log(string.format("build-cache: %s map %d field data current", context.version, bundle.mapId))
    end
  end
  return bundles
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildFieldFont(context)
  local bundle, err = FieldFontCompiler.compile(context.romFs)
  if not bundle then
    return versionFailure(err)
  end
  if context.forced or not FieldFontCacheWriter.isReady(context.cacheFs, bundle.fontId, bundle.marker) then
    FieldFontCacheWriter.write(context.cacheFs, bundle)
    context.log(string.format("build-cache: %s field font compiled", context.version))
  else
    context.log(string.format("build-cache: %s field font current", context.version))
  end
  return true
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildFieldUi(context)
  local bundle, err = FieldUiCompiler.compile(context.romFs)
  if not bundle then
    return versionFailure(err)
  end
  if context.forced or not FieldUiCacheWriter.isReady(context.cacheFs, bundle.marker) then
    FieldUiCacheWriter.write(context.cacheFs, bundle)
    context.log(string.format("build-cache: %s field ui compiled", context.version))
  else
    context.log(string.format("build-cache: %s field ui current", context.version))
  end
  return true
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildWeatherAndEffect(context)
  local weatherBundle, weatherErr = FieldWeatherCompiler.compile(context.romFs)
  if not weatherBundle then
    return versionFailure(weatherErr)
  end
  local effectBundle, effectErr = FieldEntranceIndicatorCompiler.compile(context.romFs)
  if not effectBundle then
    return versionFailure(effectErr)
  end
  if context.forced or not FieldEffectAssetCache.isReady(context.cacheFs, effectBundle.marker) then
    FieldEntranceIndicatorCacheWriter.write(context.cacheFs, effectBundle)
    context.log(string.format("build-cache: %s warp entrance field effect compiled", context.version))
  else
    context.log(string.format("build-cache: %s warp entrance field effect current", context.version))
  end
  if context.forced or not FieldWeatherCacheWriter.isReady(context.cacheFs, weatherBundle.marker) then
    FieldWeatherCacheWriter.write(context.cacheFs, weatherBundle)
    context.log(string.format("build-cache: %s field weather compiled", context.version))
  else
    context.log(string.format("build-cache: %s field weather current", context.version))
  end
  return true
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildFieldMessages(context)
  local bundle, err = FieldMessageCompiler.compile(context.romFs)
  if not bundle then
    return versionFailure(err)
  end
  if context.forced or not FieldMessageCacheWriter.isReady(context.cacheFs, bundle.marker) then
    FieldMessageCacheWriter.write(context.cacheFs, bundle)
    context.log(
      string.format("build-cache: %s field messages compiled (%d banks)", context.version, #bundle.index.bankIds)
    )
  else
    context.log(string.format("build-cache: %s field messages current", context.version))
  end
  return true
end

---@param context table
---@param fieldBundles table[]
---@return boolean|nil
---@return Errors.Error|nil
local function buildScriptAudioAndCells(context, fieldBundles)
  local scriptBundle, scriptErr = ScriptCompiler.compile(context.romFs)
  if not scriptBundle then
    return versionFailure(scriptErr)
  end
  scriptBundle.bindings = BindingCompiler.compile(fieldBundles, scriptBundle)
  if context.forced or not ScriptCacheWriter.isReady(context.cacheFs, scriptBundle.marker) then
    ScriptCacheWriter.write(context.cacheFs, scriptBundle)
    context.log(
      string.format(
        "build-cache: %s scripts compiled (%d resources, %d members)",
        context.version,
        scriptBundle.index.resourceCount,
        scriptBundle.index.scriptMemberCount
      )
    )
  else
    context.log(string.format("build-cache: %s scripts current", context.version))
  end

  local audioBundle, audioErr = AudioCompiler.compile(context.romFs)
  if not audioBundle then
    return versionFailure(audioErr)
  end
  if context.forced or not AudioCacheWriter.isReady(context.cacheFs, audioBundle.marker) then
    AudioCacheWriter.write(context.cacheFs, audioBundle)
    context.log(string.format("build-cache: %s audio compiled", context.version))
  else
    context.log(string.format("build-cache: %s audio current", context.version))
  end

  local fieldCellBundle, fieldCellErr = FieldCellCompiler.compile(context.romFs)
  if not fieldCellBundle then
    return versionFailure(fieldCellErr)
  end
  if context.forced or not FieldCellCacheWriter.isReady(context.cacheFs, fieldCellBundle.marker) then
    FieldCellCacheWriter.write(context.cacheFs, fieldCellBundle)
    context.log(string.format("build-cache: %s physical field cells compiled", context.version))
  else
    context.log(string.format("build-cache: %s physical field cells current", context.version))
  end
  return true
end

---@param context table
---@param result table
---@param entries table[]
---@param excluded table[]
---@param compileExcluded table[]
local function compileMapResult(context, result, entries, excluded, compileExcluded)
  if result.status == "excluded" then
    excluded[#excluded + 1] = {
      id = result.id,
      symbol = result.symbol,
      reason = result.reason,
      matchCount = result.matchCount,
    }
    return
  end

  local bundle, compileErr = MapAssetCompiler.compile(context.romFs, result.id)
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
    context.log(
      string.format("build-cache: %s map %d excluded: %s", context.version, result.id, Errors.format(compileErr))
    )
    return
  end

  if context.forced or not MapAssetCache.isReady(context.cacheFs, bundle.mapId, bundle.marker) then
    MapCacheWriter.write(context.cacheFs, bundle)
    context.log(string.format("build-cache: %s map %d compiled", context.version, bundle.mapId))
  else
    context.log(string.format("build-cache: %s map %d current", context.version, bundle.mapId))
  end
  for _, entry in ipairs(bundle.unresolvedMaterials) do
    context.log(
      string.format(
        "build-cache: %s map %d unresolved %s %s: material %s of %s %s:%d wants %s from %s",
        context.version,
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
    mapSection = result.mapSection,
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

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildMapsAndWorld(context)
  local entries, excluded, compileExcluded = {}, {}, {}
  for _, result in ipairs(MapAnalysis.analyze(context.romFs)) do
    compileMapResult(context, result, entries, excluded, compileExcluded)
  end
  local world = WorldManifest.stage(context.cacheFs, entries, excluded, compileExcluded)
  context.stagedWorlds[#context.stagedWorlds + 1] = world
  context.log(
    string.format(
      "build-cache: %s world.lua staged (%d maps, %d unresolved cells, %d compile-excluded)",
      context.version,
      #entries,
      #excluded,
      #compileExcluded
    )
  )
  if #compileExcluded > 0 then
    context.hasCompileExclusions = true
    context.exclusionCount = context.exclusionCount + #compileExcluded
  else
    context.strictVersions[#context.strictVersions + 1] = { cacheFs = context.cacheFs, identity = context.identity }
  end
  return true
end

---@param context table
---@return boolean|nil
---@return Errors.Error|nil
local function buildVersion(context)
  local shouldBuild, err = prepareVersion(context)
  if shouldBuild == nil then
    return versionFailure(err)
  end
  if not shouldBuild then
    return true
  end

  local ok, phaseErr = buildFieldCameras(context)
  if not ok then
    return nil, phaseErr
  end
  ok, phaseErr = buildFieldActors(context)
  if not ok then
    return nil, phaseErr
  end
  local fieldBundles
  fieldBundles, phaseErr = buildFieldData(context)
  if not fieldBundles then
    return nil, phaseErr
  end
  ok, phaseErr = buildFieldFont(context)
  if not ok then
    return nil, phaseErr
  end
  ok, phaseErr = buildFieldUi(context)
  if not ok then
    return nil, phaseErr
  end
  ok, phaseErr = buildWeatherAndEffect(context)
  if not ok then
    return nil, phaseErr
  end
  ok, phaseErr = buildFieldMessages(context)
  if not ok then
    return nil, phaseErr
  end
  ok, phaseErr = buildScriptAudioAndCells(context, fieldBundles)
  if not ok then
    return nil, phaseErr
  end
  return buildMapsAndWorld(context)
end

---@param stagedWorlds table[]
local function discardStagedWorlds(stagedWorlds)
  for _, world in ipairs(stagedWorlds) do
    world:abort()
  end
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
  local producerFingerprint = ProducerFingerprint.compute(ProducerFingerprint.appBackend() --[[@as ProducerSourceTree]])
  local allOk, hasCompileExclusions, exclusionCount = true, false, 0
  local stagedWorlds = {}
  local strictVersions = {}
  for _, version in ipairs(versionIds) do
    local context = newVersionContext(version, log, producerFingerprint, stagedWorlds, strictVersions)
    local ok, result, failureErr = pcall(buildVersion, context)
    if context.romFs then
      context.romFs:close()
    end
    if not ok then
      discardStagedWorlds(stagedWorlds)
      error(result, 0)
    end
    if result == nil then
      allOk = false
      hasCompileExclusions = hasCompileExclusions or context.hasCompileExclusions
      exclusionCount = exclusionCount + context.exclusionCount
      log("build-cache: " .. version .. " failed: " .. Errors.format(failureErr))
    end
    if result == true then
      hasCompileExclusions = hasCompileExclusions or context.hasCompileExclusions
      exclusionCount = exclusionCount + context.exclusionCount
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
    discardStagedWorlds(stagedWorlds)
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
