-- Headless ROM/asset command runner for the romdump CLI. Each command prints
-- machine-readable output and exits with a status code so agents and scripts
-- can drive imports and verification without a human. Synchronous commands quit
-- inside load(); the ROM import is a coroutine pumped by update() so progress
-- stays responsive. All love coupling lives here; the underlying work is done
-- by the romdump app and the shared libraries under libs/

local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomFs = require("romdump.src.source.RomFs")
local Errors = require("libs.errors.src.Errors")
local Cli = require("romdump.src.cli.Cli")

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

-- Dispatch the parsed command. Cli.parse rejects conflicting commands, so
-- exactly one action runs per invocation; a missing command is a usage fault.
function Runner.load(opts)
  Runner.opts = opts or {}
  Runner.importer = nil

  local command = Runner.opts.command
  if command == "import" then
    assert(Runner.opts.romPath, "import requires a ROM path")
    return Runner._startImport(Runner.opts.romPath)
  end
  if command == "build-cache" then
    return Runner._runBuildCache()
  end
  if command == "check-dump" then
    return Runner._runCheckDump()
  end
  if command == "check-derived-cache" then
    return Runner._runCheckDerivedCache()
  end
  if command == "inspect" then
    return Runner._runInspect()
  end
  if command == "inspect-sbc" then
    return Runner._runInspectSbc()
  end
  if command == "inspect-actors" then
    return Runner._runInspectActors()
  end
  print(
    "romdump: no command given (expected --import-rom, --check-dump, --check-derived-cache, "
      .. "--inspect, --inspect-sbc, "
      .. "--inspect-actors, or --build-cache)"
  )
  love.event.quit(Cli.EXIT_USAGE)
end

-- Build the derived cache from every ready dump; with --forcedump (or an
-- explicit ROM path) the ROM is imported first and the build runs when the
-- import completes.
function Runner._runBuildCache()
  local opts = Runner.opts
  if opts.forceDump then
    assert(opts.romPath, "forcedump requires a ROM path")
    return Runner._startImport(opts.romPath)
  end
  local targets = readyVersions()
  if #targets > 0 then
    return Runner._runBuild({ allowCompileExclusions = opts.allowCompileExclusions })
  end
  if opts.romPath then
    return Runner._startImport(opts.romPath)
  end
  print("build-cache: no ready dump; pass a ROM path")
  return love.event.quit(Cli.EXIT_USAGE)
end

-- Check that the current published derived artifacts can be used by the test
-- runner without recompiling. This intentionally does not recalculate source
-- dependency hashes; an explicit cache build owns freshness.
function Runner._runCheckDerivedCache()
  local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
  local CacheFs = require("libs.storage.src.CacheFs")
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

-- Audit every ready version and exit 0 only if all pass. Proves the runtime
-- boots from the private cache without the ROM.
function Runner._runCheckDump()
  local DumpAudit = require("romdump.src.source.DumpAudit")
  local targets = readyVersions()
  if #targets == 0 then
    print("check-dump: no ready version to audit")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local report = DumpAudit.run(version)
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
    local cameraReport = FieldCameraInspector.inspect(cameraBundle.profiles, cameraBundle.provenance)
    for _, line in ipairs(FieldCameraInspector.lines(cameraReport)) do
      print(line)
    end
    for _, fieldBundle in ipairs(assert(FieldMapDataCompiler.compileAll(romFs))) do
      local fieldReport = FieldMapDataInspector.inspect(fieldBundle.field, fieldBundle.dependencies)
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
-- this wrapper owns only the process exit codes; the machine-readable report
-- is the builder's own, passed through unchanged. A map whose cell could not
-- be selected is recorded as `excluded`; a resolved map
-- rejected with a structured compiler error is recorded as `compileExcluded`,
-- writes no partial artifacts, and makes the build exit nonzero unless the
-- allowCompileExclusions option accepts them. A map whose completion marker
-- already matches the current build is left in place, so an unchanged cache
-- rebuilds only what is stale. The option wins over any CLI state; callers
-- pass the parsed flag through explicitly.
---@param options { versionIds: string[]?, allowCompileExclusions: boolean?, noQuit: boolean? }|nil
---@return table|nil, string|nil
function Runner._runBuild(options)
  options = options or {}
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local report, err = CacheBuilder.buildVersions(options.versionIds or readyVersions(), {
    allowCompileExclusions = options.allowCompileExclusions,
  })
  if report then
    if not options.noQuit then
      love.event.quit(0)
    end
    return report
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
  local s = RomImporter.STATES
  if imp.state == s.COMPLETE then
    local status = imp:status()
    printImportResult(status)
    Runner.importer = nil
    if Runner.opts.command == "build-cache" then
      return Runner._finishImport(status)
    end
    love.event.quit(0)
  elseif imp.state == s.ERROR then
    local status = imp:status()
    print("import failed [" .. tostring(status.errorCode or "ERROR") .. "]: " .. Errors.format(status.error))
    love.event.quit(1)
  end
end

-- Complete a finished build-cache import: audit the imported dump and build
-- the derived cache. Runtime boot is verified by the game/application tests;
-- the ROM producer must not import runtime engine modules across the boundary.
---@param status table
function Runner._finishImport(status)
  local DumpAudit = require("romdump.src.source.DumpAudit")
  local versionId = status.versionId
  assert(type(versionId) == "string", "import must report versionId")
  local audit = DumpAudit.run(versionId)
  if not audit.ok then
    for _, line in ipairs(DumpAudit.lines(audit)) do
      print(line)
    end
    return love.event.quit(1)
  end
  local report, err = Runner._runBuild({
    versionIds = { versionId },
    allowCompileExclusions = Runner.opts.allowCompileExclusions,
    noQuit = true,
  })
  if not report then
    print("build-cache: " .. versionId .. " failed: " .. tostring(err))
    return love.event.quit(1)
  end
  return love.event.quit(0)
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
