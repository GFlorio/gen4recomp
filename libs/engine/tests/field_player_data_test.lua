-- FieldPlayerData contract tests: the strict game-owned player profile and
-- gameplay-options model. The checked-in demo manifest shape is the reference
-- record; validation is pure and receives the generated font
-- charmap plus the imported dialogue frame-index set, so name encodability
-- and frame resolution are enforced without any I/O. The cadence table next
-- to the options model is the single authority for text-speed -> ticks-per-
-- glyph.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldPlayerData = require("libs.engine.src.FieldPlayerData")

local T = {}

-- The generated field font resolves A-Z (real codes from the compiled
-- heartgold font definition); the frame set mirrors an imported class with
-- three user frames.
local CHARMAP = {
  G = 305,
  O = 313,
  L = 310,
  D = 302,
  H = 306,
  I = 307,
  K = 309,
  A = 299,
  R = 316,
}
local FRAME_INDEXES = { [0] = true, [1] = true, [2] = true }

local function context(overrides)
  local value = { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function record(overrides)
  local value = {
    profile = {
      name = "GOLD",
      gender = 0,
      trainerId = 0,
    },
    options = {
      textFrame = 0,
      textSpeed = "mid",
    },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

function T.spec_demo_record_validates_and_returns_a_copy()
  local validated = assert(FieldPlayerData.validate(record(), context()))
  Assert.deepEqual(validated, record())
  -- The returned record is a fresh copy: mutating it must not touch the
  -- caller's table, so a fresh session owns its instance of the manifest.
  validated.profile.name = "HIKARI"
  validated.options.textSpeed = "slow"
  Assert.equal(record().profile.name, "GOLD")
  Assert.equal(record().options.textSpeed, "mid")
end

function T.over_seven_glyph_names_are_rejected()
  throwsCode("PLAYER_DATA_NAME_INVALID", function()
    local _, err =
      FieldPlayerData.validate(record({ profile = { name = "ABCDEFGH", gender = 0, trainerId = 0 } }), context())
    error(err)
  end)
end

function T.empty_names_are_rejected()
  throwsCode("PLAYER_DATA_NAME_INVALID", function()
    local _, err = FieldPlayerData.validate(record({ profile = { name = "", gender = 0, trainerId = 0 } }), context())
    error(err)
  end)
end

function T.unencodable_characters_are_rejected()
  -- U+20AC (UTF-8 E2 82 AC) has no glyph in the generated field font charmap.
  throwsCode("PLAYER_DATA_NAME_INVALID", function()
    local _, err =
      FieldPlayerData.validate(record({ profile = { name = "GO\226\130\172D", gender = 0, trainerId = 0 } }), context())
    error(err)
  end)
  -- Lowercase letters are a different glyph set; the fixture charmap does not
  -- resolve them, so the same rule must reject them.
  throwsCode("PLAYER_DATA_NAME_INVALID", function()
    local _, err =
      FieldPlayerData.validate(record({ profile = { name = "gold", gender = 0, trainerId = 0 } }), context())
    error(err)
  end)
end

function T.gender_is_restricted_to_the_gendered_message_values()
  for _, gender in ipairs({ 0, 1 }) do
    Assert.notNil(
      FieldPlayerData.validate(record({ profile = { name = "GOLD", gender = gender, trainerId = 0 } }), context())
    )
  end
  for _, gender in ipairs({ 2, -1, 0.5, "male" }) do
    throwsCode("PLAYER_DATA_GENDER_INVALID", function()
      local _, err =
        FieldPlayerData.validate(record({ profile = { name = "GOLD", gender = gender, trainerId = 0 } }), context())
      error(err)
    end)
  end
end

function T.trainer_id_is_an_integer_in_range()
  for _, trainerId in ipairs({ 0, 65535 }) do
    Assert.notNil(
      FieldPlayerData.validate(record({ profile = { name = "GOLD", gender = 0, trainerId = trainerId } }), context())
    )
  end
  for _, trainerId in ipairs({ -1, 65536, 1.5, "12" }) do
    throwsCode("PLAYER_DATA_TRAINER_ID_INVALID", function()
      local _, err =
        FieldPlayerData.validate(record({ profile = { name = "GOLD", gender = 0, trainerId = trainerId } }), context())
      error(err)
    end)
  end
end

function T.text_frame_must_resolve_to_an_imported_frame_style()
  for _, frame in ipairs({ 0, 2 }) do
    Assert.notNil(FieldPlayerData.validate(record({ options = { textFrame = frame, textSpeed = "mid" } }), context()))
  end
  for _, frame in ipairs({ 3, -1, 1.5, "0" }) do
    throwsCode("PLAYER_DATA_TEXT_FRAME_INVALID", function()
      local _, err = FieldPlayerData.validate(record({ options = { textFrame = frame, textSpeed = "mid" } }), context())
      error(err)
    end)
  end
end

function T.text_speed_is_an_explicitly_supported_gameplay_value()
  for _, speed in ipairs({ "slow", "mid", "fast" }) do
    Assert.notNil(FieldPlayerData.validate(record({ options = { textFrame = 0, textSpeed = speed } }), context()))
  end
  for _, speed in ipairs({ "turbo", "MID", "normal", 2 }) do
    throwsCode("PLAYER_DATA_TEXT_SPEED_INVALID", function()
      local _, err = FieldPlayerData.validate(record({ options = { textFrame = 0, textSpeed = speed } }), context())
      error(err)
    end)
  end
end

function T.missing_profile_or_options_tables_are_rejected()
  throwsCode("PLAYER_DATA_INVALID", function()
    local _, err = FieldPlayerData.validate({ profile = nil, options = record().options }, context())
    error(err)
  end)
  throwsCode("PLAYER_DATA_INVALID", function()
    local _, err = FieldPlayerData.validate({ profile = record().profile, options = nil }, context())
    error(err)
  end)
end

function T.ticks_per_glyph_maps_every_supported_speed_to_a_positive_cadence()
  Assert.equal(FieldPlayerData.ticksPerGlyph("slow"), 3)
  Assert.equal(FieldPlayerData.ticksPerGlyph("mid"), 2)
  Assert.equal(FieldPlayerData.ticksPerGlyph("fast"), 1)
  Assert.throws(function()
    FieldPlayerData.ticksPerGlyph("turbo")
  end)
end

function T.validation_requires_the_font_and_frame_context()
  Assert.throws(function()
    FieldPlayerData.validate(record(), { charmap = CHARMAP })
  end)
  Assert.throws(function()
    FieldPlayerData.validate(record(), { frameIndexes = FRAME_INDEXES })
  end)
end

return { tests = T }
