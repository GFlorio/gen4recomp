-- Component coverage for the concrete HGSS application entry. It exercises
-- production Main Menu/Oak routing while observing the existing FieldState
-- and startup-initializer seams.

local Assert = require("tests.support.Assert")

local T = {}

local READY_VERSION = "heartgold"

local function loadApplicationModules()
  local ok, hgssGameOrError = pcall(require, "game.hgss.src.HgssGame")
  Assert.isTrue(ok, "the concrete HGSS application must provide game.hgss.src.HgssGame: " .. tostring(hgssGameOrError))
  local okGame, gameOrError = pcall(require, "game.src.Game")
  Assert.isTrue(okGame, "the HGSS application must compose the generic game host: " .. tostring(gameOrError))
  local okField, fieldOrError = pcall(require, "game.hgss.src.field.FieldState")
  Assert.isTrue(okField, "the HGSS application must own the relocated FieldState: " .. tostring(fieldOrError))
  local okInit, initOrError = pcall(require, "game.hgss.src.newgame.NewGameInitialization")
  Assert.isTrue(okInit, "the HGSS application must own the relocated new-game initializer: " .. tostring(initOrError))
  local okMenu, menuOrError = pcall(require, "game.hgss.src.menu.MainMenuState")
  Assert.isTrue(okMenu, "the HGSS application must own the relocated Main Menu: " .. tostring(menuOrError))
  local okPreview, previewOrError = pcall(require, "game.hgss.src.dev.ActorPreviewState")
  Assert.isTrue(okPreview, "the HGSS application must own the actor preview state: " .. tostring(previewOrError))
  return hgssGameOrError, fieldOrError, initOrError, menuOrError, previewOrError
end

local function fakeStore(entries)
  local store = { entries = entries, loads = {} }
  function store:list()
    return self.entries
  end
  function store:load(saveId)
    self.loads[#self.loads + 1] = saveId
    for _, entry in ipairs(self.entries) do
      if entry.saveId == saveId then
        return entry
      end
    end
    error("missing fake save " .. saveId)
  end
  return store
end

local function saveRecord(saveId)
  return {
    saveId = saveId,
    versionId = READY_VERSION,
    playerData = { profile = { name = "GOLD" } },
    playTimeSeconds = 0,
  }
end

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

local function withCompositionSpies(fn)
  local HgssGame, FieldState, NewGameInitialization, MainMenuState, ActorPreviewState = loadApplicationModules()
  local originalFieldNew = FieldState.new
  local originalApply = NewGameInitialization.apply
  local fieldCalls = {}
  local applyCalls = {}
  FieldState.new = function(game, options)
    fieldCalls[#fieldCalls + 1] = { game = game, options = options }
    return { dispose = function() end }
  end
  rawset(NewGameInitialization, "apply", function(game)
    applyCalls[#applyCalls + 1] = game
    return game
  end)

  local ok, err = pcall(function()
    fn(HgssGame, MainMenuState, fieldCalls, applyCalls, ActorPreviewState)
  end)
  FieldState.new = originalFieldNew
  rawset(NewGameInitialization, "apply", originalApply)
  if not ok then
    error(err, 0)
  end
end

local function menuView(state)
  Assert.isTrue(type(state.view) == "function", "the concrete HGSS entry must start a semantic Main Menu state")
  return state:view()
end

function T.hgss_entry_preserves_menu_continue_new_game_and_quit_routing()
  withCompositionSpies(function(HgssGame, MainMenuState, fieldCalls, applyCalls, ActorPreviewState)
    local exits = {}
    local store = fakeStore({ saveRecord("save-00000002") })
    local candidate = { saveId = "save-00000003", versionId = READY_VERSION, playerData = {} }
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

    local renderer = { disposed = 0 }
    function renderer:draw() end
    function renderer:dispose()
      self.disposed = self.disposed + 1
    end
    local oakHost = { setTextInput = function() end }

    local app = HgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      saveStore = store,
      saveValidation = saveValidation(),
      newGameCandidateFactory = function()
        return candidate
      end,
      oakIntroOptionsFactory = function(options)
        Assert.equal(options.candidate, candidate)
        Assert.equal(options.versionId, READY_VERSION)
        return {
          controller = controller,
          manifest = {},
          renderer = renderer,
          textInputHost = oakHost,
          glyphs = { "A" },
          width = 960,
          height = 540,
        }
      end,
    })

    Assert.equal(getmetatable(app).__index, require("game.src.Game"))
    Assert.equal(getmetatable(app.state).__index, MainMenuState)
    Assert.equal(menuView(app.state).kind, "main_menu")

    app.state:keypressed("down")
    app.state:keypressed("return")
    Assert.equal(fieldCalls[1].game, store.entries[1])
    Assert.equal(#store.loads, 1)
    Assert.equal(app.state.dispose ~= nil, true)

    app:setState(nil)
    local newGame = HgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      saveStore = fakeStore({}),
      saveValidation = saveValidation(),
      newGameCandidateFactory = function()
        return candidate
      end,
      oakIntroOptionsFactory = function()
        return {
          controller = controller,
          manifest = {},
          renderer = renderer,
          textInputHost = oakHost,
          glyphs = { "A" },
          width = 960,
          height = 540,
        }
      end,
    })
    Assert.equal(getmetatable(newGame.state).__index, MainMenuState)
    newGame.state:keypressed("return")
    Assert.equal(controller.started, 1)
    controller.phase = "complete"
    newGame:update(0)
    Assert.equal(#fieldCalls, 2)
    Assert.equal(fieldCalls[2].game, candidate)
    Assert.equal(applyCalls[1], candidate)

    newGame:exit({ kind = "quit" })
    Assert.deepEqual(exits, { { kind = "quit" } })
    newGame:dispose()

    local quitGame = HgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      saveStore = fakeStore({}),
      saveValidation = saveValidation(),
    })
    quitGame.state:keypressed("escape")
    Assert.deepEqual(exits, { { kind = "quit" }, { kind = "quit" } })
    quitGame:dispose()

    local previewGame = HgssGame.new({
      versionId = READY_VERSION,
      actorPreview = true,
      onExit = function() end,
      saveStore = fakeStore({}),
      saveValidation = saveValidation(),
    })
    Assert.equal(getmetatable(previewGame.state).__index, ActorPreviewState)
    previewGame:dispose()
  end)
end

return { tests = T }
