-- Interactive boot flow and top-level state dispatcher. It owns the importer
-- (pumped once per frame while a first-run import is in progress) and the
-- current UI state. Boot picks between the import screen, a version selector,
-- and the diagnostic; --map jumps straight into the 3D map diagnostic. All love
-- coupling lives here and in the launcher/game UI states. Headless ROM/asset
-- flows live in the romdump app, not here.

local GameVersion = require("libs.rom.src.GameVersion")
local RomImporter = require("libs.rom.src.RomImporter")
local MapDiagnosticState = require("game.src.game.MapDiagnosticState")
local ImportState = require("game.src.launcher.ImportState")
local VersionSelectState = require("game.src.launcher.VersionSelectState")

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
  App.importer = nil
  App.state = nil
  love.graphics.setBackgroundColor(0.08, 0.09, 0.12)
  App.saveDir = love.filesystem.getSaveDirectory()

  if App.opts.map then
    return App._bootMap(App.opts.map)
  end
  App._bootExisting()
end

-- Boot straight into the first ready version's compiled map from the warm
-- cache. With nothing ready, fall back to the importer.
function App._bootMap(idOrSymbol)
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  App.state = MapDiagnosticState.new(ready[1], idOrSymbol)
end

function App._startImport()
  App.importer = RomImporter.new({
    onComplete = function(versionId) App._onImported(versionId) end,
  })
  App.state = ImportState.new(App.importer, App.saveDir)
end

-- Fired once on a successful import: enter the diagnostic.
function App._onImported(versionId)
  App.state = MapDiagnosticState.new(versionId)
end

-- Boot decision when no ROM was supplied: one ready cache boots straight into
-- its diagnostic, both ready shows a selector, none ready offers import.
function App._bootExisting()
  local ready = readyVersions()
  if #ready == 1 then
    App.state = MapDiagnosticState.new(ready[1])
    return
  end
  if #ready >= 2 then
    App.state = VersionSelectState.new(ready, function(v) App.state = MapDiagnosticState.new(v) end)
    return
  end
  App._startImport()
end

function App.update(dt)
  if App.importer and App.importer:isBusy() then
    App.importer:update()
  end
  if App.state and App.state.update then App.state:update(dt) end
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
  if not App.importer then App._startImport() end
  App.importer:filedropped(file)
end

function App.keypressed(key)
  if App.state and App.state.keypressed then
    App.state:keypressed(key)
    return
  end
  if key == "escape" then love.event.quit(0) end
end

-- Forward pointer input to the active state when it wants it (the 3D map
-- diagnostic uses these for its free camera). Other states simply lack the hook.
local function forward(method, ...)
  local state = App.state
  if state and state[method] then state[method](state, ...) end
end

function App.mousepressed(x, y, button) forward("mousepressed", x, y, button) end
function App.mousereleased(x, y, button) forward("mousereleased", x, y, button) end
function App.mousemoved(x, y, dx, dy) forward("mousemoved", x, y, dx, dy) end
function App.wheelmoved(x, y) forward("wheelmoved", x, y) end

-- Give the active state a chance to release GPU resources on shutdown.
function App.quit()
  if App.state and App.state.quit then App.state:quit() end
end

return App
