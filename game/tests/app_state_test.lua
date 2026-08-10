-- App state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.

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

return T
