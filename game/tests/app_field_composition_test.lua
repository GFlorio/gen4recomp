-- App composes both product entry routes through one finalized GameSave-shaped
-- FieldState boundary: Oak supplies an unpublished game and Continue loads a
-- published game before entering the field.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local FieldState = require("game.src.game.FieldState")

local T = {}

local function withFieldStateSpy(fn)
  local originalNew = FieldState.new
  local originalOpts = App.opts
  local originalState = App.state
  local originalSaveStore = App.saveStore
  local captured = {}
  FieldState.new = function(game, options)
    captured.game = game
    captured.options = options
    return { dispose = function() end }
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
  App.opts = originalOpts
  App.state = originalState
  App.saveStore = originalSaveStore
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

function T.continue_loads_the_game_before_entering_field()
  local game = { saveId = "save-00000002", versionId = "heartgold", playerData = {} }
  withFieldStateSpy(function(captured)
    ---@type SaveStoreLike
    App.saveStore = {
      load = function(_, saveId)
        Assert.equal(saveId, game.saveId)
        return game
      end,
    }
    App._mainMenuResult({ kind = "continue", saveId = game.saveId })
    Assert.equal(captured.game, game)
    Assert.equal(App.state ~= nil, true)
  end)
end

return { tests = T }
