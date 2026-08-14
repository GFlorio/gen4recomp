-- Interactive boot flow and top-level state dispatcher. It owns the importer
-- (pumped once per frame while a first-run import is in progress) and the
-- current UI state. Boot picks between the import screen, a version selector,
-- and the field runtime. All love
-- coupling lives here and in the launcher/game UI states. Headless ROM/asset
-- flows live in the romdump app, not here.

local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldState = require("game.src.game.FieldState")
local ActorPreviewState = require("game.src.game.ActorPreviewState")
local ImportState = require("game.src.launcher.ImportState")
local VersionSelectState = require("game.src.launcher.VersionSelectState")

local App = {}

-- A bare `--field` (option == true) selects the runtime default map; a
-- numeric string is a map id, anything else a semantic map symbol.

---@param option boolean|string|nil
---@return string|integer|nil
local function fieldTarget(option)
  if option == true then
    return nil
  end
  if type(option) == "string" and option:match("^%d+$") then
    return tonumber(option)
  end
  return option --[[@as string|integer|nil]]
end

App.fieldTarget = fieldTarget

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then
      out[#out + 1] = id
    end
  end
  return out
end

-- The CLI session flags are applied here once, then passed as explicit
-- FieldState options: --new-field-session forces a fresh session (wiping the
-- save) instead of a resume, and --dev enables the playtest presentation.
---@param resumeSave boolean
---@return { resumeSave: boolean, resetSave: boolean, development: boolean }
local function fieldSessionOptions(resumeSave)
  local opts = App.opts
  return {
    resumeSave = resumeSave and not opts.newFieldSession,
    resetSave = opts.newFieldSession,
    development = opts.dev == true,
  }
end

function App.load(opts)
  App.opts = opts or {}
  App.importer = nil
  App.setState(nil)
  love.graphics.setBackgroundColor(0.08, 0.09, 0.12)
  App.saveDir = love.filesystem.getSaveDirectory()

  if App.opts.actors then
    return App._bootActorPreview()
  end
  if App.opts.field then
    return App._bootField(App.opts.field)
  end
  App._bootExisting()
end

-- The one transition point between top-level states: every state swap goes
-- through here so the previous state's disposal contract runs exactly once.
-- The new state becomes current before disposal, so a failing disposal can
-- never leave the app pointing at a half-disposed state. States without a
-- dispose method (stateless launcher screens) are simply replaced.

---@param nextState table|nil
function App.setState(nextState)
  local previous = App.state
  App.state = nextState
  if previous and previous.dispose then
    previous:dispose()
  end
end

-- Boot the developer preview grid over the compiled actor visuals.
function App._bootActorPreview()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  App.setState(ActorPreviewState.new(ready[1]))
end

-- Boot the fixed-step field runtime. A bare --field selects Elm's Lab;
-- an argument may select another compiled map by semantic symbol or numeric id.
function App._bootField(mapIdOrSymbol)
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  App.setState(FieldState.new(ready[1], fieldTarget(mapIdOrSymbol), fieldSessionOptions(false)))
end

function App._startImport()
  App.importer = RomImporter.new({
    onComplete = function(versionId)
      App._onImported(versionId)
    end,
  })
  App.setState(ImportState.new(App.importer, App.saveDir))
end

-- Fired once on a successful import: the session ends here, so the importer
-- is cleared and the normal field runtime is entered unless an explicit
-- developer field target was requested.
function App._onImported(versionId)
  App.importer = nil
  if App.opts.field then
    App.setState(FieldState.new(versionId, fieldTarget(App.opts.field), fieldSessionOptions(false)))
  else
    App.setState(FieldState.new(versionId, nil, fieldSessionOptions(true)))
  end
end

-- Boot decision when no ROM was supplied: one ready cache resumes its field
-- session, both ready show a selector over exactly the ready array, and none
-- ready offers import. Version selection lives here -- zero/exactly one/
-- several -- and nowhere else.
function App._bootExisting()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  if #ready == 1 then
    App.setState(FieldState.new(ready[1], nil, fieldSessionOptions(true)))
    return
  end
  App.setState(VersionSelectState.new(ready, function(versionId)
    App.setState(FieldState.new(versionId, nil, fieldSessionOptions(true)))
  end))
end

function App.update(dt)
  if App.importer and App.importer:isBusy() then
    App.importer:update()
  end
  -- A failed import ends its session: clear the importer so a stale reference
  -- is never reused. The import screen holds its own reference and keeps
  -- showing the error. (Success clears through _onImported, fired by the
  -- importer's completion callback above.)
  if App.importer and not App.importer:isBusy() and App.importer.state == RomImporter.STATES.ERROR then
    App.importer = nil
  end
  if App.state and App.state.update then
    App.state:update(dt)
  end
end

function App.draw()
  if App.state and App.state.draw then
    App.state:draw()
    return
  end
  -- The bare brand is developer-only emergency feedback on an empty frame;
  -- product mode draws nothing until a state exists.
  if App.opts.dev then
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("g4recomp", 24, 24)
  end
end

function App.filedropped(file)
  -- Import sessions are single-use. Ignore drops while an import is running;
  -- every other drop enters a fresh session through the import state, so an
  -- importer left over from a completed or failed session is never invoked.
  if App.importer and App.importer:isBusy() then
    return
  end
  App._startImport()
  App.importer:filedropped(file)
end

function App.keypressed(key, scancode, isrepeat)
  if App.state and App.state.keypressed then
    App.state:keypressed(key, scancode, isrepeat)
    return
  end
  if key == "escape" then
    love.event.quit(0)
  end
end

function App.keyreleased(key, scancode)
  if App.state and App.state.keyreleased then
    App.state:keyreleased(key, scancode)
  end
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

function App.gamepadaxis(joystick, axis, value)
  if App.state and App.state.gamepadaxis then
    App.state:gamepadaxis(joystick, axis, value)
  end
end

function App.mousepressed(x, y, button, istouch, presses)
  if App.state and App.state.mousepressed then
    App.state:mousepressed(x, y, button, istouch, presses)
  end
end

function App.mousemoved(x, y, dx, dy, istouch)
  if App.state and App.state.mousemoved then
    App.state:mousemoved(x, y, dx, dy, istouch)
  end
end

function App.mousereleased(x, y, button, istouch, presses)
  if App.state and App.state.mousereleased then
    App.state:mousereleased(x, y, button, istouch, presses)
  end
end

function App.wheelmoved(x, y)
  if App.state and App.state.wheelmoved then
    App.state:wheelmoved(x, y)
  end
end

function App.touchpressed(id, x, y, dx, dy, pressure)
  if App.state and App.state.touchpressed then
    App.state:touchpressed(id, x, y, dx, dy, pressure)
  end
end

function App.touchmoved(id, x, y, dx, dy, pressure)
  if App.state and App.state.touchmoved then
    App.state:touchmoved(id, x, y, dx, dy, pressure)
  end
end

function App.touchreleased(id, x, y, dx, dy, pressure)
  if App.state and App.state.touchreleased then
    App.state:touchreleased(id, x, y, dx, dy, pressure)
  end
end

-- Focus loss reaches the active state so held and edge input state clears.
function App.focus(focused)
  if App.state and App.state.focus then
    App.state:focus(focused)
  end
end

-- Shutdown goes through the same disposal contract as state replacement, so
-- a state is never disposed twice: the first quit disposes the current state
-- and clears it, and any further quit is a no-op.
function App.quit()
  App.setState(nil)
end

return App
