-- App composes both product entry routes through one finalized GameSave-shaped
-- FieldState boundary: Oak supplies an unpublished game and Continue supplies
-- the already loaded published game.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local FieldState = require("game.src.game.FieldState")
local NewGameInitialization = require("game.src.game.NewGameInitialization")

local T = {}

-- This suite's contract is App's FieldState composition boundary, not the
-- fresh-game startup initializer (owned by new_game_startup_continue_test);
-- the initializer is stubbed through unchanged so the fixture games below
-- need no worldState/cache.
local function withFieldStateSpy(fn)
  local originalNew = FieldState.new
  local originalApply = NewGameInitialization.apply
  local originalOpts = App.opts
  local originalState = App.state
  local originalSaveStore = App.saveStore
  local originalSaveValidation = App.saveValidation
  local captured = {}
  FieldState.new = function(game, options)
    captured.game = game
    captured.options = options
    return { dispose = function() end }
  end
  ---@diagnostic disable-next-line: duplicate-set-field -- stub the startup initializer for the FieldState composition contract only
  NewGameInitialization.apply = function(candidate)
    return candidate
  end
  ---@type AppOptions
  App.opts = {
    test = false,
    actors = false,
    dev = false,
    newGameCandidateFactory = function()
      return {}
    end,
    oakIntroOptionsFactory = function()
      return {}
    end,
  }
  App.state = nil
  App.saveStore = nil
  local ok, err = pcall(function()
    fn(captured)
  end)
  FieldState.new = originalNew
  NewGameInitialization.apply = originalApply
  App.opts = originalOpts
  App.state = originalState
  App.saveStore = originalSaveStore
  App.saveValidation = originalSaveValidation
  if not ok then
    error(err, 0)
  end
end

function T.finalized_new_game_enters_field_from_the_oak_result()
  local game = { saveId = "save-00000001", versionId = "heartgold", playerData = {} }
  withFieldStateSpy(function(captured)
    App._onOakComplete(game)
    Assert.equal(captured.game, game)
    Assert.equal(App.state ~= nil, true)
  end)
end

function T.continue_hands_the_loaded_game_to_field_without_storage_access()
  local game = { saveId = "save-00000002", versionId = "heartgold", playerData = {} }
  withFieldStateSpy(function(captured)
    App.saveStore = {
      load = function(_, saveId)
        error("Continue must not load again: " .. tostring(saveId))
      end,
    }
    App._mainMenuResult({ kind = "continue", game = game })
    Assert.equal(captured.game, game)
    Assert.equal(App.state ~= nil, true)
  end)
end

return { tests = T }
