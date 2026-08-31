-- App state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.
-- Import sessions are single-use: a file drop must always enter a fresh
-- import session through the import state and never invoke an importer left
-- over from a previous session.

---@diagnostic disable: duplicate-set-field -- seams below are stubbed per test and restored by the harness

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local ImportState = require("game.src.launcher.ImportState")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldState = require("game.hgss.src.field.FieldState")
local Game = require("game.src.Game")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")
local VersionSelectState = require("game.src.launcher.VersionSelectState")

local T = {}

-- A contract state that counts disposal invocations.
local function countingState()
  local state = { disposed = 0 }
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

-- Clear module state so tests are independent of each other and of the boot
-- flow tests.
local function fresh()
  App.state = nil
  App.importer = nil
  App.drawableWidth = nil
  App.drawableHeight = nil
end

-- One harness for every App-level seam a test can touch: fresh module state,
-- the App opts the boot/draw paths read, the RomImporter.isReady seam, a
-- FieldState.new capture (so boot tests never construct a real runtime), and
-- a graphics.print spy. Every stub is restored on every path, so no test
-- leaks options or stubs into the next.
---@class AppStateHarness
---@field prints integer
---@field captured table|nil
---@field state table
---@param opts table|nil
---@param ready fun(id: string): boolean
---@param fn fun(result: AppStateHarness)
---@return AppStateHarness
local function withAppHarness(opts, ready, fn)
  fresh()
  local originalOpts = App.opts
  local originalIsReady = RomImporter.isReady
  local originalNew = FieldState.new
  local graphics = love.graphics
  local originalPrint = graphics.print
  local originalGetDimensions = graphics.getDimensions
  local result = {
    prints = 0,
    captured = nil,
    state = countingState(),
  }
  App.opts = opts or {}
  RomImporter.isReady = ready
  FieldState.new = function(game, options)
    result.captured = { game = game, options = options }
    return result.state
  end
  graphics.print = function()
    result.prints = result.prints + 1
  end
  graphics.getDimensions = function()
    return 800, 600
  end
  local ok, err = pcall(fn, result)
  App.opts = originalOpts
  RomImporter.isReady = originalIsReady
  FieldState.new = originalNew
  graphics.print = originalPrint
  graphics.getDimensions = originalGetDimensions
  if not ok then
    error(err, 0)
  end
  return result
end

-- An importer stand-in in a given state. App reads isBusy()/state and forwards
-- drops; a terminal (complete/error) stand-in models an importer left over
-- from a finished session.
local function importerStub(state, busy)
  local importer = {
    state = state,
    busy = busy or false,
    filedroppedCalls = 0,
  }
  function importer:isBusy()
    return self.busy
  end
  function importer:filedropped()
    self.filedroppedCalls = self.filedroppedCalls + 1
  end
  return importer
end

-- A minimal dropped-file stand-in satisfying RomSource.fromDroppedFile's
-- protocol. The bytes are not a ROM, so a real importer routes the drop into
-- its reading state without touching the filesystem or caches.
local function droppedFile()
  return {
    getFilename = function()
      return "dropped.nds"
    end,
    open = function()
      return true
    end,
    read = function()
      return "not a real rom"
    end,
    close = function() end,
  }
end

function T.starting_an_import_disposes_the_active_field_state()
  fresh()
  local field = countingState()
  App.setState(field)
  App.saveDir = nil
  App._startImport()
  Assert.equal(field.disposed, 1)
  Assert.equal(getmetatable(App.state).__index, ImportState)
  Assert.notNil(App.importer)
end

-- The bare "g4recomp" draw is developer branding on an empty frame: product
-- mode draws nothing, dev mode keeps the emergency text.
function T.app_draw_keeps_the_emergency_brand_text_only_in_dev_mode()
  for _, dev in ipairs({ false, true }) do
    local result = withAppHarness({ dev = dev }, function()
      return false
    end, function()
      App.draw()
    end)
    local expected = 0
    if dev then
      expected = 1
    end
    Assert.equal(result.prints, expected, "brand text on an empty frame tracks dev mode")
  end
end

-- An import session is single-use. A file drop during gameplay after a
-- finished import (complete or failed) must enter a fresh import session
-- through the import state; the stale importer's completion callback would
-- otherwise replace the active field state unexpectedly, and re-running a
-- failed importer is just as wrong.
function T.drop_after_a_finished_import_starts_a_fresh_session()
  for _, terminalState in ipairs({ "complete", "error" }) do
    fresh()
    local stale = importerStub(terminalState)
    App.importer = stale
    App.setState({})
    App.filedropped(droppedFile())
    Assert.equal(stale.filedroppedCalls, 0, "the stale importer must not be invoked")
    Assert.isFalse(App.importer == stale, "a finished import session must not be reused")
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
    Assert.equal(App.state.importer, App.importer)
  end
end

-- Drops while an import is running are ignored: no new session, no forward to
-- the busy importer.
function T.drop_while_busy_is_ignored()
  fresh()
  local busy = importerStub("reading", true)
  App.importer = busy
  local state = {}
  App.setState(state)
  App.filedropped(droppedFile())
  Assert.equal(busy.filedroppedCalls, 0)
  Assert.equal(App.importer, busy)
  Assert.equal(App.state, state)
end

-- A failed import leaves no importer behind: the next update clears it, so a
-- stale reference can never survive the session. The import screen holds its
-- own reference and is unaffected.
function T.failed_import_is_cleared_on_the_next_update()
  fresh()
  App.importer = importerStub("error")
  local state = { update = function() end }
  App.setState(state)
  App.update(0.016)
  Assert.isNil(App.importer, "a failed import session must not linger")
  Assert.equal(App.state, state, "clearing the importer must not disturb the import screen")
end

-- The boot decision when no ROM was supplied: zero ready versions enter the
-- import state, one enters the main menu, and several offer the version
-- selector. Version selection and the new-game/continue choice each have one
-- owner, App and MainMenuState respectively.

function T.boot_existing_with_no_ready_version_starts_an_import()
  withAppHarness({}, function()
    return false
  end, function()
    App._bootExisting()
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
  end)
end

function T.boot_existing_with_one_ready_version_enters_the_main_menu()
  local result = withAppHarness({}, function(id)
    return id == "heartgold"
  end, function()
    App._bootExisting()
  end)
  Assert.isNil(result.captured, "the main menu owns the new-game/continue choice")
  Assert.equal(getmetatable(App.state).__index, Game)
  Assert.equal(getmetatable(App.state.state).__index, MainMenuState)
  Assert.isTrue(App.state.state.readyVersions.heartgold)
end

function T.boot_existing_with_two_ready_versions_offers_the_selector_over_the_ready_array()
  withAppHarness({}, function(id)
    return id == "heartgold" or id == "soulsilver"
  end, function(result)
    App._bootExisting()
    Assert.isNil(result.captured, "the selector must not boot a field state")
    local selector = App.state
    ---@cast selector table
    Assert.equal(getmetatable(selector).__index, VersionSelectState)
    Assert.deepEqual(selector.ready, { "heartgold", "soulsilver" })
    selector.onPick("soulsilver")
    local picked = result.captured
    Assert.isNil(picked, "version selection opens the main menu before field entry")
    Assert.equal(getmetatable(App.state).__index, Game)
    Assert.equal(getmetatable(App.state.state).__index, MainMenuState)
    Assert.isTrue(App.state.state.readyVersions.soulsilver)
  end)
end

return { tests = T }
