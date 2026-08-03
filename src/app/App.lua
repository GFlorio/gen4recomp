-- Top-level state dispatcher. This milestone boots a ready version straight into
-- DiagnosticState (spec §17); the interactive importer, drag-and-drop, and the
-- two-version selector are wired in Epic 8. When no dump is ready it shows the
-- import instruction screen. Boot decisions follow a reduced spec §15.3.

local GameVersion = require("src.core.GameVersion")
local RomImporter = require("src.import.RomImporter")
local DiagnosticState = require("src.ui.DiagnosticState")

local App = {}

local function flagValue(flags, name)
  for i, a in ipairs(flags) do
    if a == name then return flags[i + 1] end
  end
end

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then out[#out + 1] = id end
  end
  return out
end

-- Reduced boot decision: pick the version to diagnose, if any is ready.
local function chooseVersion(flags)
  local requested = flagValue(flags, "--version")
  if requested then
    return RomImporter.isReady(requested) and requested or nil
  end
  local ready = readyVersions()
  -- One ready boots directly; the multi-version selector is Epic 8, so for now
  -- the first ready version is shown.
  return ready[1]
end

local function saveDir()
  return love.filesystem.getSaveDirectory()
end

function App.load(flags)
  App.flags = flags or {}
  love.graphics.setBackgroundColor(0.08, 0.09, 0.12)
  local target = chooseVersion(App.flags)
  if target then
    App.state = DiagnosticState.new(target)
  end
end

function App.update(dt)
  if App.state then App.state:update(dt) end
end

function App.draw()
  if App.state then
    App.state:draw()
    return
  end
  local lg = love.graphics
  local x, y = 24, 24
  lg.setColor(1, 1, 1)
  lg.print("g4recomp", x, y)
  lg.print("HeartGold / SoulSilver ROM importer (data diagnostic milestone)", x, y + 24)
  lg.print("Drop a .nds file onto this window to import it.", x, y + 60)
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Private cache will be written under:", x, y + 96)
  lg.print(saveDir(), x, y + 116)
end

function App.filedropped(file)
  -- Import wiring arrives in Epic 8.
end

function App.keypressed(key)
  if App.state and App.state.keypressed then
    App.state:keypressed(key)
    return
  end
  if key == "escape" then love.event.quit(0) end
end

return App
