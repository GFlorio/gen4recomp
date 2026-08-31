-- The generated fresh-game startup initializer is a fresh-New-Game-only
-- transition: the HGSS game entry must invoke it on the Oak completion handoff
-- and must never invoke it on Continue.

local Assert = require("tests.support.Assert")
local HgssGame = require("game.hgss.src.HgssGame")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")

local T = {}

local function saveValidation()
  return {
    contexts = {},
    contextLoader = function()
      return {}
    end,
    validate = function(_, record)
      return record
    end,
    validatePlayerData = function(_, playerData)
      return playerData
    end,
  }
end

local function controllerFor(candidate)
  local controller = { phase = "opening_wait", started = 0, disposed = 0 }
  function controller:start()
    self.started = self.started + 1
  end
  function controller:tick() end
  function controller:press() end
  function controller:inputText() end
  function controller:deleteGlyph() end
  function controller:dispose()
    self.disposed = self.disposed + 1
  end
  function controller:view()
    return {
      phase = self.phase,
      name = "GOLD",
      message = "generated",
      visual = "background",
      genderFocus = 0,
      nameInputEnabled = false,
    }
  end
  function controller:result()
    return candidate
  end
  return controller
end

local function withSpies(fn)
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local originalApply = NewGameInitialization.apply
  local originalFieldStateNew = FieldState.new
  local applyCalls = {}
  local fieldStateCalls = {}
  rawset(NewGameInitialization, "apply", function(candidate, _)
    applyCalls[#applyCalls + 1] = candidate
    return candidate
  end)
  FieldState.new = function(game, _)
    fieldStateCalls[#fieldStateCalls + 1] = game
    return { dispose = function() end }
  end

  local ok, err = pcall(function()
    fn(applyCalls, fieldStateCalls)
  end)
  rawset(NewGameInitialization, "apply", originalApply)
  FieldState.new = originalFieldStateNew
  if not ok then
    error(err, 0)
  end
end

local function newGame(options)
  local candidate = options.candidate
  local controller = controllerFor(candidate)
  local game = HgssGame.new({
    versionId = "heartgold",
    onExit = function() end,
    saveStore = options.saveStore,
    saveValidation = saveValidation(),
    newGameCandidateFactory = function()
      return candidate
    end,
    oakIntroOptionsFactory = function()
      return {
        controller = controller,
        manifest = {},
        renderer = { draw = function() end, dispose = function() end },
        textInputHost = { setTextInput = function() end },
        glyphs = { "A" },
        width = 960,
        height = 540,
      }
    end,
  })
  return game, controller
end

function T.fresh_oak_completion_applies_startup_initialization_before_field_state()
  withSpies(function(applyCalls, fieldStateCalls)
    local candidate = { saveId = "save-00000001", versionId = "heartgold", playerData = {} }
    local game, controller = newGame({
      candidate = candidate,
      saveStore = {
        reserve = function()
          return candidate.saveId
        end,
        list = function()
          return {}
        end,
      },
    })
    game.state:keypressed("return")
    controller.phase = "complete"
    game:update(0)
    Assert.equal(#applyCalls, 1, "fresh Oak completion must apply generated startup initialization exactly once")
    Assert.equal(applyCalls[1], candidate)
    Assert.equal(#fieldStateCalls, 1)
    game:dispose()
  end)
end

function T.continue_never_reapplies_fresh_startup_initialization()
  withSpies(function(applyCalls, fieldStateCalls)
    local clearedFlagGame = {
      saveId = "save-00000002",
      versionId = "heartgold",
      playerData = { profile = { name = "GOLD" } },
      playTimeSeconds = 0,
      world = { flags = { [FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND] = false } },
    }
    local store = {
      list = function()
        return { clearedFlagGame }
      end,
      load = function()
        return clearedFlagGame
      end,
    }
    local game = HgssGame.new({
      versionId = "heartgold",
      onExit = function() end,
      saveStore = store,
      saveValidation = saveValidation(),
    })
    game.state:keypressed("down")
    game.state:keypressed("return")
    Assert.equal(#applyCalls, 0, "Continue must never invoke fresh startup initialization")
    Assert.equal(#fieldStateCalls, 1)
    Assert.equal(fieldStateCalls[1], clearedFlagGame)
    Assert.isFalse(
      fieldStateCalls[1].world.flags[FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND],
      "a cleared progression flag must survive Continue unchanged"
    )
    game:dispose()
  end)
end

return { tests = T }
