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

  if Runner.opts.build then
    return Runner._runBuild()
  end
  if Runner.opts.checkDump then
    return Runner._runCheckDump()
  end
  if Runner.opts.inspect then
    return Runner._runInspect()
  end
  if Runner.opts.importRom then
    return Runner._startImport(Runner.opts.importRom)
  end
  print("romdump: no command given (expected --import-rom, --check-dump, --inspect, or --build)")
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

-- Inventory every catalog map for every ready version and print a deterministic,
-- payload-free report. Exits 0 if every version was inspected without an
-- uncaught error, 1 otherwise.
function Runner._runInspect()
  local MapCatalog = require("romdump.src.digest.MapCatalog")
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
        for rec in MapCatalog.all() do
          local report = MapAssetInspector.inspect(romFs, rec.id)
          for _, line in ipairs(MapAssetInspector.lines(report)) do print(line) end
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

-- Compile every catalog map into the derived cache for every ready dump and
-- emit the world manifest. Idempotent: a map whose marker already matches is
-- skipped. Exits 0 only if every map of every version built.
function Runner._runBuild()
  local MapCatalog = require("romdump.src.digest.MapCatalog")
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
    local ok, err = pcall(function()
      local romFs = assert(RomFs.open(version))
      local cacheFs = CacheFs.forVersion(version)
      local entries = {}
      for rec in MapCatalog.all() do
        local bundle = assert(MapAssetCompiler.compile(romFs, rec.id))
        if MapAssetCache.isReady(cacheFs, bundle.mapId, bundle.marker) then
          print(string.format("build: %s map %d current", version, bundle.mapId))
        else
          MapCacheWriter.write(cacheFs, bundle)
          print(string.format("build: %s map %d compiled", version, bundle.mapId))
        end
        entries[#entries + 1] = {
          id = bundle.mapId, symbol = bundle.scene.mapSymbol,
          width = bundle.scene.matrix.width, height = bundle.scene.matrix.height,
          matrix = { memberId = bundle.scene.matrix.memberId,
                     x = bundle.scene.matrix.x, z = bundle.scene.matrix.z },
        }
      end
      WorldManifest.write(cacheFs, entries)
      print(string.format("build: %s world.lua written (%d maps)", version, #entries))
      romFs:close()
    end)
    if not ok then
      allOk = false
      print("build: " .. version .. " failed: " .. Errors.format(err))
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
