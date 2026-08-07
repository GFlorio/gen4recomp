-- Interactive boot flow and top-level state dispatcher. It owns the importer
-- (pumped once per frame while a first-run import is in progress) and the
-- current UI state. Boot picks between the import screen, a version selector,
-- and the field runtime; --map jumps straight into the 3D map diagnostic. All love
-- coupling lives here and in the launcher/game UI states. Headless ROM/asset
-- flows live in the romdump app, not here.

local GameVersion = require("libs.rom.src.GameVersion")
local RomImporter = require("libs.rom.src.RomImporter")
local FieldState = require("game.src.game.FieldState")
local MapDiagnosticState = require("game.src.game.MapDiagnosticState")
local ActorPreviewState = require("game.src.game.ActorPreviewState")
local ImportState = require("game.src.launcher.ImportState")
local VersionSelectState = require("game.src.launcher.VersionSelectState")

local App = {}

-- A bare `--field` (option == true) selects the runtime default map; a
-- numeric string is a map id, anything else a semantic map symbol.

---@param option boolean|string|nil
---@return string|integer|nil
local function fieldTarget(option)
  if option == true then return nil end
  if type(option) == "string" and option:match("^%d+$") then return tonumber(option) end
  return option
end

App.fieldTarget = fieldTarget

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then out[#out + 1] = id end
  end
  return out
end

local function newFieldState(versionId, target, resumeSave)
  return FieldState.new(versionId, target, {
    resumeSave = resumeSave and not App.opts.newFieldSession,
    resetSave = App.opts.newFieldSession,
  })
end

function App.load(opts)
  App.opts = opts or {}
  App.importer = nil
  App.state = nil
  love.graphics.setBackgroundColor(0.08, 0.09, 0.12)
  App.saveDir = love.filesystem.getSaveDirectory()

  if App.opts.actors then return App._bootActorPreview() end
  if App.opts.field then return App._bootField(App.opts.field) end
  if App.opts.map then
    return App._bootMap(App.opts.map)
  end
  App._bootExisting()
end

-- Boot the developer preview grid over the compiled actor visuals.
function App._bootActorPreview()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  App.state = ActorPreviewState.new(ready[1])
end

-- Boot the fixed-step field runtime. A bare --field selects Elm's Lab;
-- an argument may select another compiled map by semantic symbol or numeric id.
function App._bootField(idOrSymbol)
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  App.state = newFieldState(ready[1], fieldTarget(idOrSymbol), false)
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

-- Fired once on a successful import: enter the normal field runtime unless an
-- explicit developer field target was requested.
function App._onImported(versionId)
  if App.opts.field then
    App.state = newFieldState(versionId, fieldTarget(App.opts.field), false)
  else
    App.state = newFieldState(versionId, nil, true)
  end
end

-- Boot decision when no ROM was supplied: one ready cache resumes its field
-- session, both ready shows a selector, and none ready offers import.
function App._bootExisting()
  local ready = readyVersions()
  if #ready == 1 then
    App.state = newFieldState(ready[1], nil, true)
    return
  end
  if #ready >= 2 then
    App.state = VersionSelectState.new(ready, function(versionId)
      App.state = newFieldState(versionId, nil, true)
    end)
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

function App.keypressed(key, scancode, isrepeat)
  if App.state and App.state.keypressed then
    App.state:keypressed(key, scancode, isrepeat)
    return
  end
  if key == "escape" then love.event.quit(0) end
end


function App.keyreleased(key, scancode)
  if App.state and App.state.keyreleased then App.state:keyreleased(key, scancode) end
end

function App.gamepadpressed(joystick, button)
  if App.state and App.state.gamepadpressed then
    App.state:gamepadpressed(joystick, button)
  end
end

function App.gamepadreleased(joystick, button)
  if App.state and App.state.gamepadreleased then
    App.state:gamepadreleased(joystick, button)
  end
end

-- Focus loss reaches the active state so held and edge input state clears
-- (spec section 11.2).
function App.focus(focused)
  if App.state and App.state.focus then App.state:focus(focused) end
end

-- Give the active state a chance to release GPU resources on shutdown.
function App.quit()
  if App.state and App.state.quit then App.state:quit() end
end

return App
