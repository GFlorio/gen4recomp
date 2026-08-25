-- Applying the generated fresh-game startup artifact must change only the
-- candidate's world event state: the finalized Oak player/profile/options
-- record and the FLAG_UNK_960 opening flag set by NewGame.createCandidate
-- must be byte-for-byte unchanged, and applying an already-set flag again
-- must be a no-op.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local PlayerData = require("libs.engine.src.PlayerData")
local PlayTime = require("libs.engine.src.PlayTime")

local T = {}

local flags = FieldScriptSymbols.flagsByName

local function artifact()
  return {
    schema = "g4-new-game-init-v1",
    versionId = "heartgold",
    eventOperations = {
      {
        op = "set_flag",
        id = flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY,
        symbol = "FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY",
      },
      {
        op = "set_flag",
        id = flags.FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY,
        symbol = "FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY",
      },
      { op = "set_flag", id = flags.FLAG_HIDE_PLAYERS_ROOM_GOLD_TROPHY, symbol = "FLAG_HIDE_PLAYERS_ROOM_GOLD_TROPHY" },
      { op = "set_flag", id = flags.FLAG_HIDE_NEW_BARK_FRIEND, symbol = "FLAG_HIDE_NEW_BARK_FRIEND" },
    },
    nonFieldEffects = { "LotoIDSet" },
    sourceDependency = { standardScriptMember = 149, sha1 = "deadbeef" },
  }
end

local function finalizedCandidate()
  local eventState = FieldEventState.new()
  eventState:setFlag(flags.FLAG_UNK_960)
  local playerData = assert(PlayerData.validate({
    profile = { name = "GOLD", gender = 0, trainerId = 1234, money = 3000 },
    options = PlayerData.defaultOptions(),
  }, { charmap = { G = 1, O = 2, L = 3, D = 4 }, frameIndexes = { [0] = true } }))
  return {
    saveId = "save-00000001",
    versionId = "heartgold",
    location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, facing = "south" },
    profileDraft = { money = 3000 },
    options = PlayerData.defaultOptions(),
    playTime = PlayTime.new(),
    worldState = eventState,
    surfaceId = nil,
    playerData = playerData,
  }
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[key] = deepCopy(child)
  end
  return copy
end

function T.applying_startup_flags_preserves_finalized_player_and_fast_options()
  local NewGameInitialization = require("game.src.game.NewGameInitialization")
  local candidate = finalizedCandidate()
  local playerDataBefore = deepCopy(candidate.playerData)
  local optionsBefore = deepCopy(candidate.options)

  local result = NewGameInitialization.apply(candidate, artifact())

  Assert.deepEqual(result.playerData, playerDataBefore)
  Assert.deepEqual(result.options, optionsBefore)
  Assert.equal(result.playerData.options.textSpeed, "fastest")
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_UNK_960), "the opening flag must survive startup initialization")
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY))
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY))
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_PLAYERS_ROOM_GOLD_TROPHY))
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_NEW_BARK_FRIEND))
end

function T.applying_an_already_set_flag_is_idempotent()
  local NewGameInitialization = require("game.src.game.NewGameInitialization")
  local candidate = finalizedCandidate()
  candidate.worldState:setFlag(flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY)

  local result = NewGameInitialization.apply(candidate, artifact())

  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY))
end

return { tests = T }
