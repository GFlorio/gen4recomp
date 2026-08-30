-- The generated fresh-game startup initializer is a fresh-New-Game-only
-- transition: App must invoke it on the Oak completion handoff and must
-- never invoke it on Continue, so a progressed save's already-cleared
-- startup hide flag is never rewound by rerunning source _std_init.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local FieldState = require("game.src.game.FieldState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")

local T = {}

local function withSpies(fn)
  local NewGameInitialization = require("game.src.game.NewGameInitialization")
  local originalApply = NewGameInitialization.apply
  local originalFieldStateNew = FieldState.new
  local originalOpts = App.opts
  local originalState = App.state
  local originalSaveStore = App.saveStore

  local applyCalls = {}
  ---@diagnostic disable-next-line: duplicate-set-field -- replace the production composer with a recording fake
  NewGameInitialization.apply = function(candidate, _)
    applyCalls[#applyCalls + 1] = candidate
    return candidate
  end
  local fieldStateCalls = {}
  FieldState.new = function(game, _)
    fieldStateCalls[#fieldStateCalls + 1] = game
    return { dispose = function() end }
  end
  ---@type AppOptions
  App.opts = { test = false, actors = false, dev = false }
  App.state = nil
  App.saveStore = nil

  local ok, err = pcall(function()
    fn(applyCalls, fieldStateCalls)
  end)
  NewGameInitialization.apply = originalApply
  FieldState.new = originalFieldStateNew
  App.opts = originalOpts
  App.state = originalState
  App.saveStore = originalSaveStore
  if not ok then
    error(err, 0)
  end
end

function T.fresh_oak_completion_applies_startup_initialization_before_field_state()
  withSpies(function(applyCalls, fieldStateCalls)
    local game = { saveId = "save-00000001", versionId = "heartgold", playerData = {} }
    App._onOakComplete(game)
    Assert.equal(#applyCalls, 1, "fresh Oak completion must apply generated startup initialization exactly once")
    Assert.equal(applyCalls[1], game)
    Assert.equal(#fieldStateCalls, 1)
  end)
end

function T.continue_never_reapplies_fresh_startup_initialization()
  withSpies(function(applyCalls, fieldStateCalls)
    -- A progressed save that already cleared one source startup hide flag:
    -- Continue must hand it to FieldState exactly as loaded.
    local clearedFlagGame = {
      saveId = "save-00000002",
      versionId = "heartgold",
      playerData = {},
      world = { flags = { [FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND] = false } },
    }
    App.saveStore = {
      load = function()
        error("Continue must not load again")
      end,
    }
    App._mainMenuResult({ kind = "continue", game = clearedFlagGame })
    Assert.equal(#applyCalls, 0, "Continue must never invoke fresh startup initialization")
    Assert.equal(#fieldStateCalls, 1)
    Assert.equal(fieldStateCalls[1], clearedFlagGame)
    Assert.isFalse(
      fieldStateCalls[1].world.flags[FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND],
      "a cleared progression flag must survive Continue unchanged"
    )
  end)
end

return { tests = T }
