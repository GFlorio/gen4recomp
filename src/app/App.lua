-- Top-level state dispatcher and boot flow (spec §15.3). It owns the importer
-- (pumping it once per frame) and the current UI state. Headless modes
-- (--check-dump, --import-only) print machine-readable output and exit with a
-- status code so agents/scripts can drive imports and verification without a
-- human. Interactive modes show the import screen, a version selector, or the
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
  if App.opts.importRom then
    return App._startImport(App.opts.importRom)
  end
  App._bootExisting()
end

-- Headless dump verification: audit the requested version, or every ready
-- version when none is named, and exit 0 only if all pass (spec §18.5).
function App._runCheckDump()
  App.headless = true
  local targets = App.opts.version and { App.opts.version } or readyVersions()
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

-- Boot decision when no ROM was supplied (spec §15.3 #4-#8).
function App._bootExisting()
  local requested = App.opts.version
  if requested and RomImporter.isReady(requested) then
    App.state = DiagnosticState.new(requested)
    return
  end
  local ready = readyVersions()
  if #ready == 1 and not requested then
    App.state = DiagnosticState.new(ready[1])
    return
  end
  if #ready >= 2 and not requested then
    App.state = VersionSelectState.new(ready, function(v) App.state = DiagnosticState.new(v) end)
    return
  end
  -- Nothing ready (or a requested version that is not ready yet): offer import.
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
