-- The generated fresh-game startup initializer is a fresh-New-Game-only
-- transition: the HGSS game entry must invoke it on the Oak completion handoff
-- and must never invoke it on Continue.

local Assert = require("tests.support.Assert")
local HgssGame = require("game.hgss.src.HgssGame")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")

local T = {}

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
  local originalValidationNew = GameSaveValidation.new
  local originalStoreNew = GameSaveStore.new
  local originalCandidate = NewGame.createCandidate
  local originalOakCompose = OakIntroComposition.compose
  local applyCalls = {}
  local fieldStateCalls = {}
  local context = { stores = {}, candidates = {}, oakStates = {} }
  rawset(NewGameInitialization, "apply", function(candidate, _)
    applyCalls[#applyCalls + 1] = candidate
    local artifact = {
      schema = DerivedAssetContract.newGameInit.schema,
      versionId = candidate.versionId or "heartgold",
      operations = {
        {
          op = "set_flag",
          id = FieldScriptSymbols.flagsByName.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY,
          symbol = "FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY",
        },
        {
          op = "set_flag",
          id = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND,
          symbol = "FLAG_HIDE_NEW_BARK_FRIEND",
        },
      },
      sourceDependency = { standardScriptMember = 0, sha1 = "0000000000000000000000000000000000000000" },
    }
    return originalApply(candidate, artifact)
  end)
  FieldState.new = function(game, _)
    fieldStateCalls[#fieldStateCalls + 1] = game
    return { dispose = function() end }
  end
  rawset(GameSaveValidation, "new", function()
    return {
      validate = function(_, record)
        return record
      end,
    }
  end)
  rawset(GameSaveStore, "new", function()
    return assert(context.store, "test save store not configured")
  end)
  rawset(NewGame, "createCandidate", function()
    return assert(context.candidate, "test candidate not configured")
  end)
  rawset(OakIntroComposition, "compose", function(options)
    local state = assert(context.oakState, "test Oak state not configured")
    state.onComplete = options.onComplete
    return state
  end)

  local ok, err = pcall(function()
    fn(applyCalls, fieldStateCalls, context)
  end)
  rawset(NewGameInitialization, "apply", originalApply)
  FieldState.new = originalFieldStateNew
  rawset(GameSaveValidation, "new", originalValidationNew)
  rawset(GameSaveStore, "new", originalStoreNew)
  rawset(NewGame, "createCandidate", originalCandidate)
  rawset(OakIntroComposition, "compose", originalOakCompose)
  if not ok then
    error(err, 0)
  end
end

local function newGame(context, candidate)
  local controller = controllerFor(candidate)
  context.candidate = candidate
  context.oakState = { controller = controller, completed = false }
  function context.oakState:keypressed() end
  function context.oakState:update()
    if controller.phase == "complete" and not self.completed then
      self.completed = true
      self.onComplete(candidate)
    end
  end
  function context.oakState:dispose() end
  local game = HgssGame.new({
    versionId = "heartgold",
    onExit = function() end,
  })
  return game, controller
end

function T.fresh_oak_completion_applies_startup_initialization_before_field_state()
  withSpies(function(applyCalls, fieldStateCalls, context)
    local worldState = FieldEventState.new()
    local candidate = { saveId = "save-00000001", versionId = "heartgold", playerData = {}, worldState = worldState }
    context.store = {
      list = function()
        return {}
      end,
    }
    local game, controller = newGame(context, candidate)
    game.state:keypressed("return")
    controller.phase = "complete"
    game:update(0)
    Assert.equal(#applyCalls, 1, "fresh Oak completion must apply generated startup initialization exactly once")
    Assert.equal(applyCalls[1], candidate)
    Assert.equal(#fieldStateCalls, 1)
    Assert.equal(fieldStateCalls[1], candidate, "field construction must receive the initialized candidate")
    Assert.isTrue(
      fieldStateCalls[1].worldState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY),
      "source startup hide flag must be established before first FieldState.new"
    )
    Assert.isTrue(
      fieldStateCalls[1].worldState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND),
      "New Bark friend hide flag must be established before first FieldState.new"
    )
    game:dispose()
  end)
end

function T.continue_never_reapplies_fresh_startup_initialization()
  withSpies(function(applyCalls, fieldStateCalls, context)
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
    context.store = store
    local game = HgssGame.new({
      versionId = "heartgold",
      onExit = function() end,
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
