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

  if Runner.opts.checkDump then
    return Runner._runCheckDump()
  end
  if Runner.opts.inspectMap then
    return Runner._runInspectMap(Runner.opts.inspectMap)
  end
  if Runner.opts.buildMap then
    return Runner._runBuildMap(Runner.opts.buildMap)
  end
  if Runner.opts.importRom then
    return Runner._startImport(Runner.opts.importRom)
  end
  print("romdump: no command given (expected --import-rom, --check-dump, --inspect-map, or --build-map)")
  love.event.quit(2)
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

-- Resolve and inventory a map for every ready version and print a deterministic,
-- payload-free report. Exits 0 if any version was inspected without an uncaught
-- error, 1 otherwise.
function Runner._runInspectMap(idOrSymbol)
  local MapAssetInspector = require("libs.assets.src.MapAssetInspector")
  local targets = readyVersions()
  if #targets == 0 then
    print("inspect-map: no ready version to inspect")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local romFs, err = RomFs.open(version)
    if not romFs then
      allOk = false
      print("inspect-map: open failed for " .. version .. ": " .. Errors.format(err))
    else
      local ok, report = pcall(MapAssetInspector.inspect, romFs, idOrSymbol)
      if ok then
        for _, line in ipairs(MapAssetInspector.lines(report)) do print(line) end
      else
        allOk = false
        print("inspect-map: " .. version .. " failed: " .. Errors.format(report))
      end
      romFs:close()
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Compile the target map into the derived cache for every ready version
-- (skipping a rebuild when the marker already matches) and print the completion
-- marker. Exits 0 if every version compiled, 1 otherwise.
function Runner._runBuildMap(idOrSymbol)
  local MapAssetCompiler = require("libs.assets.src.MapAssetCompiler")
  local MapCacheWriter = require("libs.assets.src.MapCacheWriter")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local CacheFs = require("libs.rom.src.CacheFs")
  local targets = readyVersions()
  if #targets == 0 then
    print("build-map: no ready version to compile")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local ok, err = pcall(function()
      local romFs = assert(RomFs.open(version))
      local bundle = assert(MapAssetCompiler.compile(romFs, idOrSymbol))
      local cacheFs = CacheFs.forVersion(version)
      if MapAssetCache.isReady(cacheFs, bundle.mapId, bundle.marker) then
        print(string.format("build-map: %s map %d already current (%s)", version, bundle.mapId, bundle.marker))
      else
        local marker = MapCacheWriter.write(cacheFs, bundle)
        print(string.format("build-map: %s map %d compiled -> %s", version, bundle.mapId, marker))
      end
      romFs:close()
    end)
    if not ok then
      allOk = false
      print("build-map: " .. version .. " failed: " .. Errors.format(err))
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
    love.event.quit(0)
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
