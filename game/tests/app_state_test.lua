-- App state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.
-- Import sessions are single-use: a file drop must always enter a fresh
-- import session through the import state and never invoke an importer left
-- over from a previous session.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local ImportState = require("game.src.launcher.ImportState")
local ActorPreviewState = require("game.src.game.ActorPreviewState")

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

function T.set_state_disposes_previous_exactly_once()
  fresh()
  local first = countingState()
  local second = countingState()
  App.setState(first)
  App.setState(second)
  Assert.equal(first.disposed, 1)
  Assert.equal(second.disposed, 0)
  Assert.equal(App.state, second)
end

function T.set_state_without_dispose_replaces_without_error()
  fresh()
  App.setState({})
  local nextState = countingState()
  App.setState(nextState)
  Assert.equal(nextState.disposed, 0)
  Assert.equal(App.state, nextState)
end

function T.set_state_with_nil_disposes_the_current_state()
  fresh()
  local state = countingState()
  App.setState(state)
  App.setState(nil)
  Assert.equal(state.disposed, 1)
  Assert.isNil(App.state)
end

function T.quit_disposes_the_current_state_exactly_once()
  fresh()
  local state = countingState()
  App.setState(state)
  App.quit()
  App.quit()
  Assert.equal(state.disposed, 1)
  Assert.isNil(App.state)
end

function T.quit_after_replacement_never_revisits_the_old_state()
  fresh()
  local first = countingState()
  local second = countingState()
  App.setState(first)
  App.setState(second)
  App.quit()
  Assert.equal(first.disposed, 1)
  Assert.equal(second.disposed, 1)
end

function T.actor_preview_dispose_releases_exactly_once_and_is_repeat_safe()
  fresh()
  local released = {}
  local provider = {
    disposeCalls = 0,
    dispose = function(self)
      self.disposeCalls = self.disposeCalls + 1
    end,
    release = function(_, spriteId)
      released[#released + 1] = spriteId
    end,
  }
  local state = setmetatable({
    provider = provider,
    entries = { { spriteId = 1 }, { spriteId = 2 } },
  }, ActorPreviewState)
  state:dispose()
  state:dispose()
  Assert.equal(#released, 2)
  Assert.equal(provider.disposeCalls, 1)
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

-- DEV-06: the bare "g4recomp" draw is developer branding on an empty frame;
-- product mode draws nothing.
function T.app_draw_skips_the_emergency_brand_text_in_product_mode()
  fresh()
  App.opts = { dev = false }
  local prints = 0
  local graphics = love.graphics
  local originalPrint = graphics.print
  graphics.print = function()
    prints = prints + 1
  end
  local ok, err = pcall(App.draw)
  graphics.print = originalPrint
  if not ok then
    error(err, 0)
  end
  Assert.equal(prints, 0, "product mode must not draw the bare g4recomp emergency text")
end

-- DEV-07: dev mode keeps the emergency brand text on an empty frame.
function T.app_draw_keeps_the_emergency_brand_text_in_dev_mode()
  fresh()
  App.opts = { dev = true }
  local prints = 0
  local graphics = love.graphics
  local originalPrint = graphics.print
  graphics.print = function()
    prints = prints + 1
  end
  local ok, err = pcall(App.draw)
  graphics.print = originalPrint
  if not ok then
    error(err, 0)
  end
  Assert.equal(prints, 1, "dev mode keeps the emergency brand text")
end

-- An import session is single-use. A file drop during gameplay after a
-- completed import must enter a fresh import session through the import
-- state; the stale importer's completion callback would otherwise replace the
-- active field state unexpectedly.
function T.drop_after_completed_import_starts_a_fresh_session()
  fresh()
  local stale = importerStub("complete")
  App.importer = stale
  App.setState({})
  App.filedropped(droppedFile())
  Assert.equal(stale.filedroppedCalls, 0, "the stale importer must not be invoked")
  Assert.isFalse(App.importer == stale, "a completed import session must not be reused")
  Assert.notNil(App.importer)
  Assert.equal(getmetatable(App.state).__index, ImportState)
  Assert.equal(App.state.importer, App.importer)
end

-- The same single-use contract holds after a failed import: the dropped file
-- starts a fresh session rather than re-running the failed importer.
function T.drop_after_failed_import_starts_a_fresh_session()
  fresh()
  local stale = importerStub("error")
  App.importer = stale
  App.setState({})
  App.filedropped(droppedFile())
  Assert.equal(stale.filedroppedCalls, 0, "a failed import session must not be reused")
  Assert.isFalse(App.importer == stale)
  Assert.equal(getmetatable(App.state).__index, ImportState)
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

return T
