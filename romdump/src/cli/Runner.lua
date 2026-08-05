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

local Runner = {}

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then out[#out + 1] = id end
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
  if Runner.opts.analyzeMaps then
    return Runner._runAnalyzeMaps()
  end
  if Runner.opts.importRom then
    return Runner._startImport(Runner.opts.importRom)
  end
  print("romdump: no command given (expected --import-rom, --check-dump, "
    .. "--analyze-maps, --inspect, or --build-cache)")
  love.event.quit(2)
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
        for _, line in ipairs(MapAnalysis.lines(results)) do print(line) end
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
  local targets = readyVersions()
  if #targets == 0 then
    print("check-dump: no ready version to audit")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local report = DumpAudit.run(version)
    for _, line in ipairs(DumpAudit.lines(report)) do print(line) end
    if not report.ok then allOk = false end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Inventory every renderable map for every ready version and print a deterministic,
-- payload-free report. Exits 0 if every version was inspected without an
-- uncaught error, 1 otherwise.
function Runner._runInspect()
  local MapAnalysis = require("romdump.src.digest.MapAnalysis")
  local MapAssetInspector = require("romdump.src.digest.MapAssetInspector")
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
        for _, result in ipairs(MapAnalysis.analyze(romFs)) do
          if result.status == "resolved" then
            local report = MapAssetInspector.inspect(romFs, result.id)
            for _, line in ipairs(MapAssetInspector.lines(report)) do print(line) end
          else
            print(string.format("inspect: %s map %d %s excluded: %s",
              version, result.id, result.symbol, result.reason))
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
-- emit the world manifest. Maps rejected with a structured compiler error are
-- recorded as exclusions; programming errors still abort the build. A
-- build-cache invocation first clears all derived output.
function Runner._runBuild()
  local MapAnalysis = require("romdump.src.digest.MapAnalysis")
  local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
  local MapCacheWriter = require("romdump.src.digest.MapCacheWriter")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local WorldManifest = require("romdump.src.digest.WorldManifest")
  local CacheFs = require("libs.rom.src.CacheFs")
  local targets = readyVersions()
  if #targets == 0 then
    print("build: no ready version to compile")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local romFs
    local ok, err = pcall(function()
      romFs = assert(RomFs.open(version))
      local cacheFs = CacheFs.forVersion(version)
      MapAssetCache.invalidateAllDerived(cacheFs)
      print(string.format("build-cache: %s derived cache cleared", version))
      local entries, excluded = {}, {}
      for _, result in ipairs(MapAnalysis.analyze(romFs)) do
        if result.status == "excluded" then
          excluded[#excluded + 1] = {
            id = result.id, symbol = result.symbol, reason = result.reason,
            matchCount = result.matchCount,
          }
        else
          local bundle, compileErr = MapAssetCompiler.compile(romFs, result.id)
          if not bundle then
            assert(Errors.is(compileErr), "compiler failure must be a structured error")
            excluded[#excluded + 1] = {
              id = result.id,
              symbol = result.symbol,
              reason = "compile_error",
              matchCount = result.matchCount,
              errorCode = compileErr.code,
              errorMessage = compileErr.message,
            }
            print(string.format("build-cache: %s map %d excluded: %s",
              version, result.id, Errors.format(compileErr)))
          else
            if MapAssetCache.isReady(cacheFs, bundle.mapId, bundle.marker) then
              print(string.format("build-cache: %s map %d current", version, bundle.mapId))
            else
              MapCacheWriter.write(cacheFs, bundle)
              print(string.format("build-cache: %s map %d compiled", version, bundle.mapId))
            end
            entries[#entries + 1] = {
              id = bundle.mapId, symbol = bundle.scene.mapSymbol,
              width = bundle.scene.matrix.width, height = bundle.scene.matrix.height,
              matrix = { memberId = result.matrixMemberId,
                         x = result.matrixX, z = result.matrixZ,
                         index = result.matrixIndex,
                         landDataMemberId = result.landDataMemberId,
                         selection = result.source, matchCount = result.matchCount },
            }
          end
        end
      end
      WorldManifest.write(cacheFs, entries, excluded)
      print(string.format("build-cache: %s world.lua written (%d maps, %d excluded)",
        version, #entries, #excluded))
    end)
    if romFs then romFs:close() end
    if not ok then
      allOk = false
      print("build-cache: " .. version .. " failed: " .. Errors.format(err))
    end
  end
  love.event.quit(allOk and 0 or 1)
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
  if not imp then return end
  if imp.state == "complete" then
    printImportResult(imp:status())
    Runner.importer = nil
    if Runner.opts.buildCache then
      Runner._runBuild()
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
  if not imp then return end
  if imp:isBusy() then imp:update() end
  Runner._maybeExit()
end

return Runner
