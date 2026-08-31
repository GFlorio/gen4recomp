-- Composes the concrete HeartGold/SoulSilver application over the generic game host.

local Game = require("game.src.Game")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local NewGame = require("game.hgss.src.newgame.NewGame")
local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
local FieldState = require("game.hgss.src.field.FieldState")
local ActorPreviewState = require("game.hgss.src.dev.ActorPreviewState")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")
local RepoFs = require("game.src.RepoFs")

---@class HgssGameOptions
---@field versionId string
---@field onExit fun(result: table|nil)
---@field development boolean?
---@field actorPreview boolean?
---@field saveStore table?
---@field saveValidation GameSaveValidation?
---@field newGameCandidateFactory (fun(options: table): table?)?
---@field oakIntroOptionsFactory (fun(options: table): table?)?
---@field oakIntroHost table?

local HgssGame = {}

local function fieldStateOptions(options, saveStore, saveValidation)
  return {
    development = options.development == true,
    saveStore = saveStore,
    saveValidation = saveValidation,
    audioOutput = options.oakIntroHost and options.oakIntroHost.audioOutput,
  }
end

local function newGameCandidate(options, saveStore, versionId)
  local factory = options.newGameCandidateFactory
  if factory then
    local candidate = factory({ saveService = saveStore, versionId = versionId })
    return assert(candidate, "New Game candidate factory returned no candidate")
  end
  return NewGame.createCandidate({
    saveService = saveStore,
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

---@param options HgssGameOptions
---@param game Game
---@param saveStore table
---@param saveValidation GameSaveValidation
---@param versionId string
local function installRoutes(options, game, saveStore, saveValidation, versionId)
  local function enterField(record)
    game:setState(FieldState.new(record, fieldStateOptions(options, saveStore, saveValidation)))
  end

  local function onOakComplete(result)
    assert(type(result) == "table" and result.playerData ~= nil, "Oak intro completed without a finalized game")
    enterField(NewGameInitialization.apply(result))
  end

  local function bootOakIntro()
    local candidate = newGameCandidate(options, saveStore, versionId)
    local input = {
      candidate = candidate,
      versionId = versionId,
    }
    for key, value in pairs(options.oakIntroHost or {}) do
      input[key] = value
    end
    local factory = options.oakIntroOptionsFactory
    if factory then
      local oakOptions = factory(input)
      assert(type(oakOptions) == "table", "Oak intro options factory must return a table")
      ---@cast oakOptions OakIntroStateOptions
      oakOptions.onComplete = onOakComplete
      game:setState(OakIntroState.new(oakOptions))
      return
    end
    input.onComplete = onOakComplete
    game:setState(OakIntroComposition.compose(input))
  end

  local function onMenuResult(result)
    if result.kind == "quit" then
      game:exit(result)
    elseif result.kind == "new_game" then
      bootOakIntro()
    elseif result.kind == "continue" then
      enterField(assert(result.game))
    end
  end

  local width, height = love.graphics.getDimensions()
  game:setState(MainMenuState.new({
    saveStore = saveStore,
    readyVersions = { versionId },
    width = width,
    height = height,
    onResult = onMenuResult,
  }))
end

---@param options HgssGameOptions
---@return Game
function HgssGame.new(options)
  assert(type(options) == "table", "HgssGame requires options")
  local versionId = assert(options.versionId, "HgssGame requires a versionId")
  assert(type(versionId) == "string" and versionId ~= "", "HgssGame versionId is invalid")
  assert(type(options.onExit) == "function", "HgssGame requires an onExit callback")

  local saveValidation = options.saveValidation
    or GameSaveValidation.new({ overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()) })
  local saveStore = options.saveStore
    or GameSaveStore.new(SaveFs.global(), {
      recordValidate = function(record)
        return saveValidation:validate(record)
      end,
    })
  local game = Game.new({ onExit = options.onExit })

  if options.actorPreview then
    game:setState(ActorPreviewState.new(versionId))
  else
    installRoutes(options, game, saveStore, saveValidation, versionId)
  end
  return game
end

return HgssGame
