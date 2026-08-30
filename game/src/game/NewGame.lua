-- HGSS New Game coordinator. It reserves a stable identity, creates the
-- source-shaped unpublished opening state, and later finalizes the partial
-- Oak profile without publishing gameplay to storage.

local GameSave = require("libs.hgss.src.save.GameSave")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local PlayerData = require("libs.hgss.src.save.PlayerData")

local NewGame = {}

local SOURCE_FACING = {
  [0] = "north",
  [1] = "south",
  [2] = "west",
  [3] = "east",
}

local function assertMapIdentity(mapIdentity)
  assert(type(mapIdentity) == "table", "NewGame requires a source map identity")
  assert(type(mapIdentity.mapSymbol) == "string", "NewGame map identity requires mapSymbol")
  assert(type(mapIdentity.fieldX) == "number" and mapIdentity.fieldX % 1 == 0, "NewGame fieldX must be an integer")
  assert(type(mapIdentity.fieldZ) == "number" and mapIdentity.fieldZ % 1 == 0, "NewGame fieldZ must be an integer")
  assert(SOURCE_FACING[mapIdentity.sourceFacing] ~= nil, "NewGame source facing is invalid")
end

---@param options table
---@return table candidate
function NewGame.createCandidate(options)
  assert(type(options) == "table", "NewGame.createCandidate requires options")
  assert(
    type(options.saveService) == "table" and type(options.saveService.reserve) == "function",
    "NewGame requires a save reservation"
  )
  assert(type(options.versionId) == "string", "NewGame requires a versionId")
  assert(
    type(options.eventState) == "table" and type(options.eventState.setFlag) == "function",
    "NewGame requires event state"
  )
  assert(
    type(options.scriptSymbols) == "table" and type(options.scriptSymbols.flagsByName) == "table",
    "NewGame requires script symbols"
  )
  assertMapIdentity(options.mapIdentity)
  local openingFlag = options.scriptSymbols.flagsByName.FLAG_UNK_960
  assert(type(openingFlag) == "number", "NewGame requires the opening event flag symbol")

  local saveId = options.saveService:reserve()
  local valid, saveIdError = GameSave.validateSaveId(saveId)
  if not valid then
    error(saveIdError)
  end
  options.eventState:setFlag(openingFlag)

  return {
    saveId = saveId,
    versionId = options.versionId,
    location = {
      mapSymbol = options.mapIdentity.mapSymbol,
      fieldX = options.mapIdentity.fieldX,
      fieldZ = options.mapIdentity.fieldZ,
      facing = SOURCE_FACING[options.mapIdentity.sourceFacing],
    },
    profileDraft = { money = 3000 },
    options = PlayerData.defaultOptions(),
    playTime = PlayTime.new(),
    worldState = options.eventState,
    surfaceId = nil,
    playerData = nil,
  }
end

---@param candidate table
---@param confirmation table { name: string, gender: integer }
---@param options table { randomU32: fun(): number, playerDataContext: table }
---@return table|nil, Errors.Error?
function NewGame.finalize(candidate, confirmation, options)
  assert(type(candidate) == "table" and candidate.playerData == nil, "NewGame candidate must be partial")
  assert(type(confirmation) == "table", "NewGame confirmation is required")
  assert(type(options) == "table" and type(options.randomU32) == "function", "NewGame requires a randomU32 provider")
  assert(type(options.playerDataContext) == "table", "NewGame requires PlayerData validation context")

  local draft, draftError = PlayerData.validate({
    profile = {
      name = confirmation.name,
      gender = confirmation.gender,
      trainerId = 0,
      money = candidate.profileDraft.money,
    },
    options = candidate.options,
  }, options.playerDataContext)
  if not draft then
    return nil, draftError
  end

  local trainerId = options.randomU32()
  assert(
    type(trainerId) == "number"
      and trainerId == math.floor(trainerId)
      and trainerId >= 0
      and trainerId <= PlayerData.MAX_TRAINER_ID,
    "randomU32 must return an unsigned 32-bit integer"
  )
  local finalized, finalError = PlayerData.validate({
    profile = {
      name = draft.profile.name,
      gender = draft.profile.gender,
      trainerId = trainerId,
      money = draft.profile.money,
    },
    options = draft.options,
  }, options.playerDataContext)
  if not finalized then
    return nil, finalError
  end
  candidate.playerData = finalized
  return candidate
end

return NewGame
