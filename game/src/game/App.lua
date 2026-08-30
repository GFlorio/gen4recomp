-- Interactive boot flow and top-level state dispatcher. It owns the importer
-- (pumped once per frame while a first-run import is in progress) and the
-- current UI state. Boot picks between the import screen, a version selector,
-- and the field runtime. All love
-- coupling lives here and in the launcher/game UI states. Headless ROM/asset
-- flows live in the romdump app, not here.

local WindowConfig = require("game.src.WindowConfig")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local GameSaveStore = require("libs.engine.src.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local NewGame = require("game.src.game.NewGame")
local NewGameInitialization = require("game.src.game.NewGameInitialization")
local FieldState = require("game.src.game.FieldState")
local ActorPreviewState = require("game.src.game.ActorPreviewState")
local MainMenuState = require("game.src.game.MainMenuState")
local GameSaveValidation = require("game.src.game.GameSaveValidation")
local OakIntroState = require("game.src.game.OakIntroState")
local OakIntroComposition = require("game.src.game.OakIntroComposition")
local ImportState = require("game.src.launcher.ImportState")
local VersionSelectState = require("game.src.launcher.VersionSelectState")
local RepoFs = require("game.src.game.RepoFs")

---@class SaveStoreLike
---@field load fun(self: SaveStoreLike, saveId: string): table|nil, any
---@class App
---@field opts AppOptions
---@field saveStore (GameSaveStore|SaveStoreLike)?
---@field drawableWidth number?
---@field drawableHeight number?
local App = {}

---@class AppOptions : GameOptions
---@field saveStore (GameSaveStore|SaveStoreLike)?
---@field newGameCandidateFactory (fun(options: table): table)?
---@field oakIntroOptionsFactory (fun(options: table): table)?
---@field oakIntroHost table? true host seams for product-composition tests
---@field saveValidation GameSaveValidation?

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then
      out[#out + 1] = id
    end
  end
  return out
end

---@return FieldStateOptions
local function fieldStateOptions()
  return {
    development = App.opts.dev == true,
    saveStore = App.saveStore,
    saveValidation = App.saveValidation,
    audioOutput = App.opts.oakIntroHost and App.opts.oakIntroHost.audioOutput,
  }
end

function App.load(opts)
  App.opts = opts or {}
  App.drawableWidth, App.drawableHeight = love.graphics.getDimensions()
  App.saveValidation = App.opts.saveValidation
    or GameSaveValidation.new({ overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()) })
  local function recordValidate(record)
    return App.saveValidation:validate(record)
  end
  App.saveStore = App.opts.saveStore or GameSaveStore.new(SaveFs.global(), {
    recordValidate = recordValidate,
  })
  App.importer = nil
  App.setState(nil)
  love.graphics.setBackgroundColor(unpack(WindowConfig.BACKGROUND_COLOR))
  App.saveDir = love.filesystem.getSaveDirectory()

  if App.opts.actors then
    return App._bootActorPreview()
  end
  App._bootExisting()
end

function App._mainMenuResult(result)
  App.menuResult = result
  if result.kind == "quit" then
    love.event.quit(0)
  elseif result.kind == "new_game" then
    App._bootOakIntro()
  elseif result.kind == "continue" then
    App.setState(FieldState.new(assert(result.game), fieldStateOptions()))
  end
end

local function newGameCandidate(versionId)
  local factory = App.opts.newGameCandidateFactory
  if factory then
    local candidate = factory({ saveService = App.saveStore, versionId = versionId })
    return assert(candidate, "New Game candidate factory returned no candidate")
  end
  return NewGame.createCandidate({
    saveService = App.saveStore,
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  })
end

-- Build the production Oak state from generated visual/message/audio resources.
-- An explicit factory remains a test seam; normal New Game uses the production
-- composer so missing generated resources fail the transition loudly.
function App._bootOakIntro()
  local versionId = assert(App.versionId, "New Game needs a selected version")
  local candidate = newGameCandidate(versionId)
  local input = {
    candidate = candidate,
    versionId = versionId,
  }
  for key, value in pairs(App.opts.oakIntroHost or {}) do
    input[key] = value
  end
  local factory = App.opts.oakIntroOptionsFactory
  if factory then
    local options = factory(input)
    assert(type(options) == "table", "Oak intro options factory must return a table")
    ---@cast options OakIntroStateOptions
    local function onComplete(result)
      App._onOakComplete(result)
    end
    options.onComplete = onComplete
    App.setState(OakIntroState.new(options))
    return
  end
  local function onComplete(result)
    App._onOakComplete(result)
  end
  input.onComplete = onComplete
  App.setState(OakIntroComposition.compose(input))
end

-- The candidate is finalized in memory, but remains reserved and unpublished
-- until the receiving field flow explicitly writes it.
function App._onOakComplete(result)
  assert(type(result) == "table" and result.playerData ~= nil, "Oak intro completed without a finalized game")
  result = NewGameInitialization.apply(result)
  App.setState(FieldState.new(result, fieldStateOptions()))
end

function App._bootMainMenu(versions)
  assert(type(versions) == "table" and #versions == 1, "Main Menu needs exactly one selected version")
  App.versionId = versions[1]
  local width, height = love.graphics.getDimensions()
  local function onResult(result)
    App._mainMenuResult(result)
  end
  App.setState(MainMenuState.new({
    saveStore = App.saveStore or assert(App.opts.saveStore, "App needs a global save store"),
    readyVersions = versions,
    width = width,
    height = height,
    onResult = onResult,
  }))
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

function App._startImport()
  local function onComplete(versionId)
    App._onImported(versionId)
  end
  App.importer = RomImporter.new({
    onComplete = onComplete,
  })
  App.setState(ImportState.new(App.importer, App.saveDir))
end

-- Fired once on a successful import: the session ends here, so the importer
-- is cleared and the normal product boot flow is entered.
function App._onImported(versionId)
  App.importer = nil
  App._bootMainMenu({ versionId })
end

-- Boot decision when no ROM was supplied: one ready cache opens its Main Menu,
-- both ready show a selector over exactly the ready array, and none ready
-- offers import. Version selection lives here -- zero/exactly one/
-- several -- and nowhere else.
function App._bootExisting()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  if #ready == 1 then
    App._bootMainMenu(ready)
    return
  end
  App.setState(VersionSelectState.new(ready, function(versionId)
    App._bootMainMenu({ versionId })
  end))
end

function App.update(dt)
  App._syncDrawableSize()
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

function App.resize(width, height)
  App.drawableWidth = width
  App.drawableHeight = height
  if App.state and App.state.resize then
    App.state:resize(width, height)
  end
end

function App._syncDrawableSize()
  local width, height = love.graphics.getDimensions()
  if width == App.drawableWidth and height == App.drawableHeight then
    return
  end
  App.drawableWidth = width
  App.drawableHeight = height
  if App.state and App.state.resize then
    App.state:resize(width, height)
  end
end

function App.draw()
  App._syncDrawableSize()
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
  App._syncDrawableSize()
  if App.state and App.state.mousepressed then
    App.state:mousepressed(x, y, button, istouch, presses)
  end
end

function App.mousemoved(x, y, dx, dy, istouch)
  App._syncDrawableSize()
  if App.state and App.state.mousemoved then
    App.state:mousemoved(x, y, dx, dy, istouch)
  end
end

function App.mousereleased(x, y, button, istouch, presses)
  App._syncDrawableSize()
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
  App._syncDrawableSize()
  if App.state and App.state.touchpressed then
    App.state:touchpressed(id, x, y, dx, dy, pressure)
  end
end

function App.touchmoved(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App.state and App.state.touchmoved then
    App.state:touchmoved(id, x, y, dx, dy, pressure)
  end
end

function App.touchreleased(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App.state and App.state.touchreleased then
    App.state:touchreleased(id, x, y, dx, dy, pressure)
  end
end

function App.textinput(text)
  if App.state and App.state.textinput then
    App.state:textinput(text)
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
