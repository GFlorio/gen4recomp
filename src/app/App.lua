-- Top-level state dispatcher and boot flow. It owns the importer (pumping it
-- once per frame) and the current UI state. Headless modes (--check-dump,
-- --import-only) print machine-readable output and exit with a status code so
-- agents/scripts can drive imports and verification without a human.
-- Interactive modes show the import screen, a version selector, or the
-- diagnostic. All love coupling lives here and in the ui states.

local GameVersion = require("src.core.GameVersion")
local RomImporter = require("src.import.RomImporter")
local DiagnosticState = require("src.ui.DiagnosticState")
local ImportState = require("src.ui.ImportState")
local VersionSelectState = require("src.ui.VersionSelectState")
local DumpAudit = require("src.core.DumpAudit")
local Errors = require("src.import.Errors")

local App = {}

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then out[#out + 1] = id end
  end
  return out
end

function App.load(opts)
  App.opts = opts or {}
  App.headless = false
  App.importer = nil
  App.state = nil
  -- Graphics is absent on headless invocations (see conf.lua); guard it.
  if love.graphics then love.graphics.setBackgroundColor(0.08, 0.09, 0.12) end
  App.saveDir = love.filesystem.getSaveDirectory()

  if App.opts.checkDump then
    return App._runCheckDump()
  end
  if App.opts.inspectMap then
    return App._runInspectMap(App.opts.inspectMap)
  end
  if App.opts.buildMap then
    return App._runBuildMap(App.opts.buildMap)
  end
  if App.opts.importRom then
    return App._startImport(App.opts.importRom)
  end
  App._bootExisting()
end

-- Headless dump verification: audit every ready version and exit 0 only if all
-- pass. Proves the runtime boots from the private cache without the ROM.
function App._runCheckDump()
  App.headless = true
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

-- Headless map inspector: resolve and inventory a map for every ready version
-- and print a deterministic, payload-free report. Exits 0 if any version was
-- inspected without an uncaught error, 1 otherwise.
function App._runInspectMap(idOrSymbol)
  App.headless = true
  local MapAssetInspector = require("src.import.MapAssetInspector")
  local RomFs = require("src.core.RomFs")
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

-- Headless map compiler: compile the target map into the derived cache for
-- every ready version (skipping a rebuild when the marker already matches) and
-- print the completion marker. Exits 0 if every version compiled, 1 otherwise.
function App._runBuildMap(idOrSymbol)
  App.headless = true
  local MapAssetCompiler = require("src.import.MapAssetCompiler")
  local MapCacheWriter = require("src.import.MapCacheWriter")
  local MapAssetCache = require("src.core.MapAssetCache")
  local CacheFs = require("src.import.CacheFs")
  local RomFs = require("src.core.RomFs")
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

function App._startImport(path)
  App.headless = App.opts.importOnly == true
  App.importer = RomImporter.new({
    onComplete = function(versionId) App._onImported(versionId) end,
  })
  App.state = ImportState.new(App.importer, App.saveDir)
  if path then
    App.importer:startPath(path)
  end
end

-- Fired once on a successful import. Interactive: enter the diagnostic. Headless
-- exit is handled in update() so both success and failure share one path.
function App._onImported(versionId)
  if not App.headless then
    App.state = DiagnosticState.new(versionId)
  end
end

-- Boot decision when no ROM was supplied: one ready cache boots straight into
-- its diagnostic, both ready shows a selector, none ready offers import.
function App._bootExisting()
  local ready = readyVersions()
  if #ready == 1 then
    App.state = DiagnosticState.new(ready[1])
    return
  end
  if #ready >= 2 then
    App.state = VersionSelectState.new(ready, function(v) App.state = DiagnosticState.new(v) end)
    return
  end
  App._startImport(nil)
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

function App._maybeExitHeadless()
  local imp = App.importer
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

function App.update(dt)
  if App.importer and App.importer:isBusy() then
    App.importer:update()
  end
  if App.state and App.state.update then App.state:update(dt) end
  if App.headless then App._maybeExitHeadless() end
end

function App.draw()
  if App.state and App.state.draw then
    App.state:draw()
    return
  end
  love.graphics.setColor(1, 1, 1)
  love.graphics.print("g4recomp", 24, 24)
end

function App.filedropped(file)
  -- If an importer is present (import screen) route the drop there; otherwise
  -- spin one up. Ignore drops while a busy import is running.
  if App.importer and App.importer:isBusy() then return end
  if not App.importer then App._startImport(nil) end
  App.importer:filedropped(file)
end

function App.keypressed(key)
  if App.state and App.state.keypressed then
    App.state:keypressed(key)
    return
  end
  if key == "escape" then love.event.quit(0) end
end

return App
