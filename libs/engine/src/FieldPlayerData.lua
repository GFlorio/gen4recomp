-- The project-owned player profile and gameplay-options model: the single
-- authority for the player name, gender, and trainer ID, and for the
-- gameplay text-frame index and text speed that dialogue presentation
-- consumes. Pure domain module: no love dependency and no I/O. Validation
-- receives the generated field-font charmap and the imported dialogue
-- frame-index set as context, so encodability and frame resolution are
-- enforced without touching the filesystem. A fresh field session copies and
-- validates the checked-in initial manifest; a resumed session uses the
-- required saved player-data bucket.

local Errors = require("libs.errors.src.Errors")

local FieldPlayerData = {}

-- Explicitly supported gameplay text speeds and their fixed-tick glyph
-- cadence (ticks per revealed glyph). Owned next to the options model so the
-- dialogue print path never chooses a renderer-side arbitrary reveal speed.
FieldPlayerData.TEXT_SPEEDS = {
  slow = 3,
  mid = 2,
  fast = 1,
}

-- The gender values the existing gendered-message path distinguishes
-- (0 = male, 1 = female); anything else is not a playable profile.
FieldPlayerData.GENDERS = { [0] = true, [1] = true }

FieldPlayerData.MIN_NAME_GLYPHS = 1
FieldPlayerData.MAX_NAME_GLYPHS = 7
FieldPlayerData.MAX_TRAINER_ID = 65535

-- The fixed-tick glyph cadence for a supported text speed.
---@param textSpeed string
---@return integer
function FieldPlayerData.ticksPerGlyph(textSpeed)
  local cadence = FieldPlayerData.TEXT_SPEEDS[textSpeed]
  assert(cadence ~= nil, "unknown text speed " .. tostring(textSpeed))
  return cadence
end

-- Iterate the UTF-8 glyphs of a string (leading byte determines the width),
-- matching the generated field font's text iteration.
---@param text string
---@param fn fun(glyph: string)
local function eachGlyph(text, fn)
  local position = 1
  while position <= #text do
    local byte = text:byte(position)
    local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
    fn(text:sub(position, math.min(position + width - 1, #text)))
    position = position + width
  end
end

-- Strict validation (raising). The record must be exactly the model shape:
-- the profile (name/gender/trainerId) and the options (textFrame/textSpeed)
-- tables, every field within its strict range, the name encodable by the
-- generated field font, and the text frame resolving to an imported frame
-- style. Missing tables and unknown enum values are errors, never defaults.
---@param record table
---@param context table { charmap: table, frameIndexes: table<integer, true> }
---@return table validated copy
local function validate(record, context)
  if type(record) ~= "table" then
    Errors.raise("PLAYER_DATA_INVALID", "player data must be a table", {})
  end
  local profile = record.profile
  if type(profile) ~= "table" then
    Errors.raise("PLAYER_DATA_INVALID", "player profile must be a table", {})
  end
  if type(profile.name) ~= "string" then
    Errors.raise("PLAYER_DATA_NAME_INVALID", "player name must be a string", { name = profile.name })
  end
  local glyphs = 0
  eachGlyph(profile.name, function()
    glyphs = glyphs + 1
  end)
  if glyphs < FieldPlayerData.MIN_NAME_GLYPHS or glyphs > FieldPlayerData.MAX_NAME_GLYPHS then
    Errors.raise(
      "PLAYER_DATA_NAME_INVALID",
      "player name must be " .. FieldPlayerData.MIN_NAME_GLYPHS .. ".." .. FieldPlayerData.MAX_NAME_GLYPHS .. " glyphs",
      { name = profile.name, glyphs = glyphs }
    )
  end
  eachGlyph(profile.name, function(glyph)
    if context.charmap[glyph] == nil then
      Errors.raise(
        "PLAYER_DATA_NAME_INVALID",
        "player name contains a character the generated field font cannot encode",
        { character = glyph }
      )
    end
  end)
  if FieldPlayerData.GENDERS[profile.gender] ~= true then
    Errors.raise("PLAYER_DATA_GENDER_INVALID", "player gender must be one of the gendered-message values", {
      gender = profile.gender,
    })
  end
  local trainerId = profile.trainerId
  if
    type(trainerId) ~= "number"
    or trainerId % 1 ~= 0
    or trainerId < 0
    or trainerId > FieldPlayerData.MAX_TRAINER_ID
  then
    Errors.raise("PLAYER_DATA_TRAINER_ID_INVALID", "player trainer id must be an integer in 0..65535", {
      trainerId = trainerId,
    })
  end
  local options = record.options
  if type(options) ~= "table" then
    Errors.raise("PLAYER_DATA_INVALID", "player gameplay options must be a table", {})
  end
  local textFrame = options.textFrame
  if type(textFrame) ~= "number" or textFrame % 1 ~= 0 or context.frameIndexes[textFrame] ~= true then
    Errors.raise("PLAYER_DATA_TEXT_FRAME_INVALID", "text frame index must resolve to an imported frame style", {
      textFrame = textFrame,
    })
  end
  if FieldPlayerData.TEXT_SPEEDS[options.textSpeed] == nil then
    Errors.raise("PLAYER_DATA_TEXT_SPEED_INVALID", "text speed must be an explicitly supported gameplay value", {
      textSpeed = options.textSpeed,
    })
  end
  return {
    profile = {
      name = profile.name,
      gender = profile.gender,
      trainerId = trainerId,
    },
    options = {
      textFrame = textFrame,
      textSpeed = options.textSpeed,
    },
  }
end

-- Public validation boundary: returns a fresh validated copy of the record
-- or nil, err with a PLAYER_DATA_* structured error. The context is required
-- by contract: the generated font charmap and the imported frame-index set.
---@param record table
---@param context table { charmap: table, frameIndexes: table<integer, true> }
---@return table|nil, Errors.Error?
function FieldPlayerData.validate(record, context)
  assert(
    type(context) == "table" and type(context.charmap) == "table" and type(context.frameIndexes) == "table",
    "FieldPlayerData.validate requires the generated charmap and frame-index context"
  )
  local ok, result = pcall(validate, record, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldPlayerData
