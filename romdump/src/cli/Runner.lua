-- Headless ROM/asset command runner for the romdump CLI. Each command prints
-- machine-readable output and exits with a status code so agents and scripts
-- can drive imports and verification without a human. Synchronous commands quit
-- inside load(); the ROM import is a coroutine pumped by update() so progress
-- stays responsive. All love coupling lives here; the underlying work is done
-- by libs/rom and libs/assets.

local GameVersion = require("libs.rom.src.GameVersion")
local RomImporter = require("libs.rom.src.RomImporter")
local RomFs = require("libs.rom.src.RomFs")
local DumpAudit = require("libs.rom.src.DumpAudit")
local Errors = require("libs.rom.src.Errors")
local CachePipeline = require("romdump.src.CachePipeline")

local Runner = {}

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then
      out[#out + 1] = id
    end
  end
  return out
end

function Runner.load(opts)
  Runner.opts = opts or {}
  Runner.importer = nil

  if Runner.opts.buildCache then
    if Runner.opts.forceDump then
      assert(Runner.opts.importRom, "forcedump requires a ROM path")
      return Runner._startImport(Runner.opts.importRom)
    end
    local targets = readyVersions()
    if #targets > 0 then
      return Runner._runBuild()
    end
    if Runner.opts.importRom then
      return Runner._startImport(Runner.opts.importRom)
    end
    print("build-cache: no ready dump; pass a ROM path")
    return love.event.quit(2)
  end
  if Runner.opts.checkDump then
    return Runner._runCheckDump()
  end
  if Runner.opts.inspect then
    return Runner._runInspect()
  end
  if Runner.opts.inspectSbc then
    return Runner._runInspectSbc()
  end
  if Runner.opts.inspectActors then
    return Runner._runInspectActors()
  end
  if Runner.opts.analyzeMaps then
    return Runner._runAnalyzeMaps()
  end
  if Runner.opts.genScriptOverrides then
    return Runner._runGenScriptOverrides()
  end
  if Runner.opts.importRom then
    return Runner._startImport(Runner.opts.importRom)
  end
  print(
    "romdump: no command given (expected --import-rom, --check-dump, "
      .. "--analyze-maps, --inspect, --inspect-sbc, "
      .. "--inspect-actors, --build-cache, or --gen-script-overrides)"
  )
  love.event.quit(2)
end

-- Regenerate the checked-in script overrides for the New Bark slice
-- (data/scripts/overrides/<id>.lua) from the first ready dump. Files are
-- written into the repo tree (the override system's checked-in content), not
-- the cache; identical dumps produce byte-identical files.
function Runner._runGenScriptOverrides()
  local OverrideGenerator = require("romdump.src.digest.script.OverrideGenerator")
  local targets = readyVersions()
  if #targets == 0 then
    print("gen-script-overrides: no ready version")
    return love.event.quit(1)
  end
  local root = love.filesystem.getSourceBaseDirectory()
  for _, version in ipairs(targets) do
    local romFs, err = RomFs.open(version)
    if not romFs then
      print("gen-script-overrides: open failed for " .. version .. ": " .. Errors.format(err))
      return love.event.quit(1)
    end
    local ok, files = pcall(OverrideGenerator.generate, romFs)
    romFs:close()
    if not ok then
      print("gen-script-overrides: " .. tostring(files))
      return love.event.quit(1)
    end
    for _, file in ipairs(files) do
      local full = root .. "/" .. file.path
      local parent = full:match("^(.*)/[^/]+$")
      if parent then
        os.execute(("mkdir -p %q"):format(parent))
      end
      local handle, openErr = io.open(full, "wb")
      if not handle then
        print("gen-script-overrides: open failed for " .. file.path .. ": " .. tostring(openErr))
        return love.event.quit(1)
      end
      handle:write(file.text)
      handle:close()
    end
    -- Rewrite the override manifest with the exact generated ids so the
    -- loader never enumerates the directory.
    local manifest = "return {\n"
    for _, file in ipairs(files) do
      manifest = manifest .. "  " .. string.format("%q", file.id) .. ",\n"
    end
    manifest = manifest .. "}\n"
    local ScriptLoader = require("libs.engine.src.script.ScriptLoader")
    local manifestPath = root .. "/" .. ScriptLoader.OVERRIDE_MANIFEST
    local mh, mErr = io.open(manifestPath, "wb")
    if not mh then
      print("gen-script-overrides: open failed for override manifest: " .. tostring(mErr))
      return love.event.quit(1)
    end
    mh:write(manifest)
    mh:close()
    print(string.format("gen-script-overrides: %s wrote %d override files", version, #files))
    return love.event.quit(0)
  end
end

-- Derive payload-free map resolution facts from every ready canonical dump.
function Runner._runAnalyzeMaps()
  local MapAnalysis = require("romdump.src.digest.MapAnalysis")
  local targets = readyVersions()
  if #targets == 0 then
    print("analyze-maps: no ready version to analyze")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local romFs, err = RomFs.open(version)
    if not romFs then
      allOk = false
      print("analyze-maps: open failed for " .. version .. ": " .. Errors.format(err))
    else
      print("version\t" .. version)
      local ok, results = pcall(MapAnalysis.analyze, romFs)
      if ok then
        for _, line in ipairs(MapAnalysis.lines(results)) do
          print(line)
        end
      else
        allOk = false
        print("analyze-maps: " .. version .. " failed: " .. Errors.format(results))
      end
      romFs:close()
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Audit every ready version and exit 0 only if all pass. Proves the runtime
-- boots from the private cache without the ROM.
function Runner._runCheckDump()
  local pipeline = CachePipeline.production()
  local targets = pipeline:readyVersions()
  if #targets == 0 then
    print("check-dump: no ready version to audit")
    return love.event.quit(1)
  end
  local allOk = true
  local reports = pipeline:auditReady()
  for _, version in ipairs(targets) do
    local report = reports[version]
    for _, line in ipairs(DumpAudit.lines(report)) do
      print(line)
    end
    if not report.ok then
      allOk = false
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Inventory the SBC transform features used by every terrain and building model
-- in the ROM. Read-only: it decodes models and writes no cache artifacts.
function Runner._runInspectSbc()
  local SbcInventory = require("romdump.src.digest.SbcInventory")
  local targets = readyVersions()
  if #targets == 0 then
    print("inspect-sbc: no ready version to inspect")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local romFs, err = RomFs.open(version)
    if not romFs then
      allOk = false
      print("inspect-sbc: open failed for " .. version .. ": " .. Errors.format(err))
    else
      local ok, report = pcall(SbcInventory.scan, romFs)
      if ok then
        print("version\t" .. version)
        for _, line in ipairs(SbcInventory.lines(report)) do
          print(line)
        end
      else
        allOk = false
        print("inspect-sbc: " .. version .. " failed: " .. Errors.format(report))
      end
      romFs:close()
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Compile the complete field-actor set for every ready version and print its
-- structural facts. Read-only: it writes no cache artifact and emits no
-- ROM-derived image bytes.
function Runner._runInspectActors()
  local FieldActorCompiler = require("romdump.src.digest.FieldActorCompiler")
  local FieldActorInspector = require("romdump.src.digest.FieldActorInspector")
  local targets = readyVersions()
  if #targets == 0 then
    print("inspect-actors: no ready version to inspect")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local romFs, err = RomFs.open(version)
    if not romFs then
      allOk = false
      print("inspect-actors: open failed for " .. version .. ": " .. Errors.format(err))
    else
      local ok, bundle = pcall(function()
        return assert(FieldActorCompiler.compile(romFs))
      end)
      if ok then
        print("version\t" .. version)
        for _, line in ipairs(FieldActorInspector.lines(FieldActorInspector.inspect(bundle))) do
          print(line)
        end
      else
        allOk = false
        print("inspect-actors: " .. version .. " failed: " .. Errors.format(bundle))
      end
      romFs:close()
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Inventory every renderable map for every ready version and print a deterministic,
-- payload-free report. Exits 0 if every version was inspected without an
-- uncaught error, 1 otherwise.
function Runner._runInspect()
  local MapAnalysis = require("romdump.src.digest.MapAnalysis")
  local MapAssetInspector = require("romdump.src.digest.MapAssetInspector")
  local FieldCameraCompiler = require("romdump.src.digest.FieldCameraCompiler")
  local FieldCameraInspector = require("romdump.src.digest.FieldCameraInspector")
  local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
  local FieldMapDataInspector = require("romdump.src.digest.FieldMapDataInspector")
  local targets = readyVersions()
  if #targets == 0 then
    print("inspect: no ready version to inspect")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local romFs, err = RomFs.open(version)
    if not romFs then
      allOk = false
      print("inspect: open failed for " .. version .. ": " .. Errors.format(err))
    else
      local ok, err2 = pcall(function()
        local cameraBundle = assert(FieldCameraCompiler.compile(romFs))
        local cameraReport = FieldCameraInspector.inspect(cameraBundle.profiles)
        for _, line in ipairs(FieldCameraInspector.lines(cameraReport)) do
          print(line)
        end
        for _, fieldBundle in ipairs(assert(FieldMapDataCompiler.compileAll(romFs))) do
          local fieldReport = FieldMapDataInspector.inspect(fieldBundle.field)
          for _, line in ipairs(FieldMapDataInspector.lines(fieldReport)) do
            print(line)
          end
        end
        for _, result in ipairs(MapAnalysis.analyze(romFs)) do
          if result.status == "resolved" then
            local report = MapAssetInspector.inspect(romFs, result.id)
            for _, line in ipairs(MapAssetInspector.lines(report)) do
              print(line)
            end
          else
            print(string.format("inspect: %s map %d %s excluded: %s", version, result.id, result.symbol, result.reason))
          end
        end
      end)
      if not ok then
        allOk = false
        print("inspect: " .. version .. " failed: " .. Errors.format(err2))
      end
      romFs:close()
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Compile every supported map into the derived cache for every ready dump and
-- emit the world manifest. A map whose cell could not be selected is recorded as
-- `excluded`; a resolved map rejected with a structured compiler error is
-- recorded as `compileExcluded`, writes no partial artifacts, and makes the build
-- exit nonzero unless --allow-compile-exclusions is given. Programming errors
-- still abort the build. A map whose completion marker already matches the
-- current build is left in place, so an unchanged cache rebuilds only what is
-- stale.
---@param options { versionIds: string[]?, noQuit: boolean? }|nil
---@return table|nil, string|nil
function Runner._runBuild(options)
  options = options or {}
  local MapAnalysis = require("romdump.src.digest.MapAnalysis")
  local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
  local MapCacheWriter = require("romdump.src.digest.MapCacheWriter")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local WorldManifest = require("romdump.src.digest.WorldManifest")
  local CacheFs = require("libs.rom.src.CacheFs")
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
  local targets = options.versionIds or readyVersions()
  if #targets == 0 then
    print("build: no ready version to compile")
    if not options.noQuit then
      love.event.quit(1)
    end
    return nil, "no ready version to compile"
  end
  local allOk, compileExclusions = true, false
  for _, version in ipairs(targets) do
    local romFs
    local ok, err = pcall(function()
      romFs = assert(RomFs.open(version))
      local cacheFs = CacheFs.forVersion(version)
      local cameraBundle = assert(FieldCameraCompiler.compile(romFs))
      if FieldCameraCacheWriter.isReady(cacheFs, cameraBundle.marker) then
        print(string.format("build-cache: %s field cameras current", version))
      else
        FieldCameraCacheWriter.write(cacheFs, cameraBundle)
        print(string.format("build-cache: %s field cameras compiled", version))
      end
      local actorBundle = assert(FieldActorCompiler.compile(romFs))
      if FieldActorCacheWriter.isReady(cacheFs, actorBundle.marker) then
        print(string.format("build-cache: %s field actors current", version))
      else
        FieldActorCacheWriter.write(cacheFs, actorBundle)
        print(
          string.format("build-cache: %s field actors compiled (%d sprites)", version, #actorBundle.index.spriteIds)
        )
      end
      for _, fieldBundle in ipairs(assert(FieldMapDataCompiler.compileAll(romFs))) do
        if FieldMapDataCache.isReady(cacheFs, fieldBundle.mapId, fieldBundle.marker) then
          print(string.format("build-cache: %s map %d field data current", version, fieldBundle.mapId))
        else
          FieldMapDataCacheWriter.write(cacheFs, fieldBundle)
          print(string.format("build-cache: %s map %d field data compiled", version, fieldBundle.mapId))
        end
      end
      local fontBundle = assert(FieldFontCompiler.compile(romFs))
      if FieldFontCacheWriter.isReady(cacheFs, fontBundle.fontId, fontBundle.marker) then
        print(string.format("build-cache: %s field font current", version))
      else
        FieldFontCacheWriter.write(cacheFs, fontBundle)
        print(string.format("build-cache: %s field font compiled", version))
      end
      local messageBundle = assert(FieldMessageCompiler.compile(romFs))
      if FieldMessageCacheWriter.isReady(cacheFs, messageBundle.marker) then
        print(string.format("build-cache: %s field messages current", version))
      else
        FieldMessageCacheWriter.write(cacheFs, messageBundle)
        print(
          string.format("build-cache: %s field messages compiled (%d banks)", version, #messageBundle.index.bankIds)
        )
      end
      local scriptBundle = assert(ScriptCompiler.compile(romFs))
      if ScriptCacheWriter.isReady(cacheFs, scriptBundle.marker) then
        print(string.format("build-cache: %s scripts current", version))
      else
        ScriptCacheWriter.write(cacheFs, scriptBundle)
        print(
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
            print(string.format("build-cache: %s map %d excluded: %s", version, result.id, Errors.format(compileErr)))
          else
            if MapAssetCache.isReady(cacheFs, bundle.mapId, bundle.marker) then
              print(string.format("build-cache: %s map %d current", version, bundle.mapId))
            else
              MapCacheWriter.write(cacheFs, bundle)
              print(string.format("build-cache: %s map %d compiled", version, bundle.mapId))
            end
            -- Untextured on the DS too, so the map is usable; still reported,
            -- because a mis-routed pack would show up here as a flood.
            for _, entry in ipairs(bundle.unresolvedMaterials) do
              print(
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
      print(
        string.format(
          "build-cache: %s world.lua written (%d maps, %d unresolved cells, %d compile-excluded)",
          version,
          #entries,
          #excluded,
          #compileExcluded
        )
      )
      if #compileExcluded > 0 then
        compileExclusions = true
      end
    end)
    if romFs then
      romFs:close()
    end
    if not ok then
      allOk = false
      print("build-cache: " .. version .. " failed: " .. Errors.format(err))
    end
  end
  -- The cache written above is usable, so the scan always finishes; an
  -- unsupported asset still has to be visible to CI, hence the nonzero exit
  -- unless the caller asked for an exploratory run.
  if compileExclusions and not Runner.opts.allowCompileExclusions then
    print("build-cache: compile exclusions remain; " .. "rerun with --allow-compile-exclusions to accept them")
    allOk = false
  end
  if not options.noQuit then
    love.event.quit(allOk and 0 or 1)
  end
  if allOk then
    return { current = true }
  end
  return nil, "cache preparation failed"
end

function Runner._startImport(path)
  Runner.importer = RomImporter.new()
  Runner.importer:startPath(path)
end

-- Print a compact summary of a finished import for scripted consumers.
local function printImportResult(status)
  local r = status.report
  print("import complete: " .. status.versionId)
  print("  sha1:   " .. r.sha1)
  print("  files:  " .. r.fatEntryCount .. " FAT entries, " .. r.totalBytesWritten .. " bytes")
  if r.matrix then
    print(string.format("  matrix: %q %dx%d", r.matrix.name, r.matrix.width, r.matrix.height))
  end
end

function Runner._maybeExit()
  local imp = Runner.importer
  if not imp then
    return
  end
  if imp.state == "complete" then
    printImportResult(imp:status())
    local imported = imp:status()
    Runner.importer = nil
    if Runner.opts.buildCache then
      local pipeline = CachePipeline.production({
        prepareVersion = function(versionId)
          return Runner._runBuild({ versionIds = { versionId }, noQuit = true })
        end,
        importSource = function(source)
          assert(source == Runner.opts.importRom, "source import path changed while importing")
          return { versionId = imported.versionId }
        end,
        -- scripts/test.sh owns the isolated root and removes it in its EXIT
        -- trap. The LÖVE process only consumes that already-isolated root.
        createIsolatedRoot = function()
          return "script-owned-isolated-root"
        end,
        removeIsolatedRoot = function()
          return true
        end,
      })
      local result = pipeline:runSource(Runner.opts.importRom)
      result.runtime:dispose()
      love.event.quit(0)
    else
      love.event.quit(0)
    end
  elseif imp.state == "error" then
    local s = imp:status()
    print("import failed [" .. tostring(s.errorCode or "ERROR") .. "]: " .. Errors.format(s.error))
    love.event.quit(1)
  end
end

function Runner.update()
  local imp = Runner.importer
  if not imp then
    return
  end
  if imp:isBusy() then
    imp:update()
  end
  Runner._maybeExit()
end

return Runner
