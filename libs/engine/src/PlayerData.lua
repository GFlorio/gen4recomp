-- The project-owned player profile and gameplay-options model: the single
-- authority for the player name, gender, trainer ID, and money, and for the
-- gameplay text-frame index and text speed that dialogue presentation
-- consumes. Pure domain module: no love dependency and no I/O. Validation
-- receives the generated field-font charmap and the imported dialogue
-- frame-index set as context, so encodability and frame resolution are
-- enforced without touching the filesystem.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local PlayerData = {}

PlayerData.TEXT_SPEEDS = { slow = 3, mid = 2, fast = 1, fastest = 1 }
PlayerData.GENDERS = { [0] = true, [1] = true }
PlayerData.MIN_NAME_GLYPHS = 1
PlayerData.MAX_NAME_GLYPHS = 7
PlayerData.MAX_TRAINER_ID = 0xFFFFFFFF
PlayerData.MAX_MONEY = 999999

local function isFiniteInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---@param textSpeed string
---@return integer
function PlayerData.ticksPerGlyph(textSpeed)
  local cadence = PlayerData.TEXT_SPEEDS[textSpeed]
  assert(cadence ~= nil, "unknown text speed " .. tostring(textSpeed))
  return cadence
end

local function validate(record, context)
  if type(record) ~= "table" then
    Errors.raise(FieldErrors.PLAYER_DATA_INVALID, "player data must be a table", {})
  end
  local profile = record.profile
  if type(profile) ~= "table" then
    Errors.raise(FieldErrors.PLAYER_DATA_INVALID, "player profile must be a table", {})
  end
  if type(profile.name) ~= "string" then
    Errors.raise(FieldErrors.PLAYER_DATA_NAME_INVALID, "player name must be a string", { name = profile.name })
  end
  local glyphs = 0
  local unencodableGlyph
  for glyph in Utf8Glyphs.iter(profile.name) do
    glyphs = glyphs + 1
    if glyphs > PlayerData.MAX_NAME_GLYPHS then
      Errors.raise(
        FieldErrors.PLAYER_DATA_NAME_INVALID,
        "player name must be 1..7 glyphs",
        { name = profile.name, glyphs = glyphs }
      )
    end
    if context.charmap[glyph] == nil then
      unencodableGlyph = glyph
    end
  end
  if unencodableGlyph ~= nil then
    Errors.raise(
      FieldErrors.PLAYER_DATA_NAME_INVALID,
      "player name contains a character the generated field font cannot encode",
      { character = unencodableGlyph }
    )
  end
  if glyphs < PlayerData.MIN_NAME_GLYPHS then
    Errors.raise(FieldErrors.PLAYER_DATA_NAME_INVALID, "player name must be 1..7 glyphs", {
      name = profile.name,
      glyphs = glyphs,
    })
  end
  if PlayerData.GENDERS[profile.gender] ~= true then
    Errors.raise(FieldErrors.PLAYER_DATA_GENDER_INVALID, "player gender must be one of the gendered-message values", {
      gender = profile.gender,
    })
  end
  local trainerId = profile.trainerId
  if not isFiniteInteger(trainerId) or trainerId < 0 or trainerId > PlayerData.MAX_TRAINER_ID then
    Errors.raise(FieldErrors.PLAYER_DATA_TRAINER_ID_INVALID, "player trainer id must be an integer in 0..4294967295", {
      trainerId = trainerId,
    })
  end
  local money = profile.money
  if not isFiniteInteger(money) or money < 0 or money > PlayerData.MAX_MONEY then
    Errors.raise(FieldErrors.PLAYER_DATA_MONEY_INVALID, "player money must be an integer in 0..999999", {
      money = money,
    })
  end
  local options = record.options
  if type(options) ~= "table" then
    Errors.raise(FieldErrors.PLAYER_DATA_INVALID, "player gameplay options must be a table", {})
  end
  local textFrame = options.textFrame
  if type(textFrame) ~= "number" or textFrame % 1 ~= 0 or context.frameIndexes[textFrame] ~= true then
    Errors.raise(
      FieldErrors.PLAYER_DATA_TEXT_FRAME_INVALID,
      "text frame index must resolve to an imported frame style",
      {
        textFrame = textFrame,
      }
    )
  end
  if PlayerData.TEXT_SPEEDS[options.textSpeed] == nil then
    Errors.raise(
      FieldErrors.PLAYER_DATA_TEXT_SPEED_INVALID,
      "text speed must be an explicitly supported gameplay value",
      {
        textSpeed = options.textSpeed,
      }
    )
  end
  return {
    profile = { name = profile.name, gender = profile.gender, trainerId = trainerId, money = money },
    options = { textFrame = textFrame, textSpeed = options.textSpeed },
  }
end

---@param record table
---@param context table { charmap: table, frameIndexes: table<integer, true> }
---@return table|nil, Errors.Error?
function PlayerData.validate(record, context)
  assert(
    type(context) == "table" and type(context.charmap) == "table" and type(context.frameIndexes) == "table",
    "PlayerData.validate requires the generated charmap and frame-index context"
  )
  local ok, result = pcall(validate, record, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

function PlayerData.defaultOptions()
  return { textSpeed = "fastest", textFrame = 0 }
end

---@param trainerId integer
---@return integer
function PlayerData.visibleTrainerId(trainerId)
  assert(isFiniteInteger(trainerId) and trainerId >= 0 and trainerId <= PlayerData.MAX_TRAINER_ID)
  return trainerId % 65536
end

return PlayerData
