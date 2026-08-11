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

-- Open one RomFs per ready version, run `work(romFs, version)` under pcall,
-- and close the handle on every path; a per-version failure is printed with
-- the shared message shape and later versions still run. Returns nil when no
-- version is ready, true when every version ran, false on any failure.
---@param prefix string
---@param work fun(romFs: RomFs, version: string)
---@return boolean|nil
local function forEachReadyVersion(prefix, work)
  local targets = readyVersions()
  if #targets == 0 then
    return nil
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local romFs, err = RomFs.open(version)
    if not romFs then
      allOk = false
      print(prefix .. ": open failed for " .. version .. ": " .. Errors.format(err))
    else
      local ok, result = pcall(work, romFs, version)
      romFs:close()
      if not ok then
        allOk = false
        print(prefix .. ": " .. version .. " failed: " .. Errors.format(result))
      end
    end
  end
  return allOk
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
  if Runner.opts.checkDerivedCache then
    return Runner._runCheckDerivedCache()
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
    "romdump: no command given (expected --import-rom, --check-dump, --check-derived-cache, "
      .. "--analyze-maps, --inspect, --inspect-sbc, "
      .. "--inspect-actors, --build-cache, or --gen-script-overrides)"
  )
  love.event.quit(2)
end

-- Check that the current published derived artifacts can be used by the test
-- runner without recompiling. This intentionally does not recalculate source
-- dependency hashes; an explicit cache build owns freshness.
function Runner._runCheckDerivedCache()
  local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
  local CacheFs = require("libs.rom.src.CacheFs")
  local targets = readyVersions()
  if #targets == 0 then
    print("check-derived-cache: no ready dump")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local ok, reason = DerivedCacheAudit.isAvailable(CacheFs.forVersion(version))
    print("derived cache: " .. version .. " -> " .. (ok and "PASS" or "FAIL"))
    if not ok then
      allOk = false
      print("  " .. reason)
    end
  end
  love.event.quit(allOk and 0 or 1)
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
  local allOk = forEachReadyVersion("analyze-maps", function(romFs, version)
    print("version\t" .. version)
    local results = MapAnalysis.analyze(romFs)
    for _, line in ipairs(MapAnalysis.lines(results)) do
      print(line)
    end
  end)
  if allOk == nil then
    print("analyze-maps: no ready version to analyze")
    return love.event.quit(1)
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
  local allOk = forEachReadyVersion("inspect-sbc", function(romFs, version)
    print("version\t" .. version)
    local report = SbcInventory.scan(romFs)
    for _, line in ipairs(SbcInventory.lines(report)) do
      print(line)
    end
  end)
  if allOk == nil then
    print("inspect-sbc: no ready version to inspect")
    return love.event.quit(1)
  end
  love.event.quit(allOk and 0 or 1)
end

-- Compile the complete field-actor set for every ready version and print its
-- structural facts. Read-only: it writes no cache artifact and emits no
-- ROM-derived image bytes.
function Runner._runInspectActors()
  local FieldActorCompiler = require("romdump.src.digest.FieldActorCompiler")
  local FieldActorInspector = require("romdump.src.digest.FieldActorInspector")
  local allOk = forEachReadyVersion("inspect-actors", function(romFs, version)
    print("version\t" .. version)
    local bundle = assert(FieldActorCompiler.compile(romFs))
    for _, line in ipairs(FieldActorInspector.lines(FieldActorInspector.inspect(bundle))) do
      print(line)
    end
  end)
  if allOk == nil then
    print("inspect-actors: no ready version to inspect")
    return love.event.quit(1)
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
  local allOk = forEachReadyVersion("inspect", function(romFs, version)
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
  if allOk == nil then
    print("inspect: no ready version to inspect")
    return love.event.quit(1)
  end
  love.event.quit(allOk and 0 or 1)
end

-- Build the derived cache for every listed version (or every ready version)
-- and quit with the build status. The pipeline itself lives in CacheBuilder;
-- this wrapper owns only the process exit codes and the prepareVersion report
-- shape. A map whose cell could not be selected is recorded as `excluded`; a
-- resolved map rejected with a structured compiler error is recorded as
-- `compileExcluded`, writes no partial artifacts, and makes the build exit
-- nonzero unless --allow-compile-exclusions is given. A map whose completion
-- marker already matches the current build is left in place, so an unchanged
-- cache rebuilds only what is stale.
---@param options { versionIds: string[]?, noQuit: boolean? }|nil
---@return table|nil, string|nil
function Runner._runBuild(options)
  options = options or {}
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local report, err = CacheBuilder.buildVersions(options.versionIds or readyVersions(), {
    allowCompileExclusions = Runner.opts.allowCompileExclusions,
  })
  if report then
    if not options.noQuit then
      love.event.quit(0)
    end
    return { current = true }
  end
  if not options.noQuit then
    love.event.quit(1)
  end
  return nil, err
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
      pipeline:runSource(Runner.opts.importRom)
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
