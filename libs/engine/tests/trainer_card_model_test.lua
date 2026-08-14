-- TrainerCardModel contract tests: the pure read-only projection of the
-- required FieldPlayerData profile. The model carries only currently
-- authoritative gameplay values — name, gender, and trainerId pass through
-- from the validated player-data record; every other card field is nil as
-- the explicit "not implemented by gameplay" value, never substituted with
-- zero. Semantic values only: no formatting, no zero-padding, no labels or
-- coordinates. The model is a fresh copy; mutating it never touches the
-- caller's player-data record.

local Assert = require("tests.support.Assert")
local TrainerCardModel = require("libs.engine.src.TrainerCardModel")

local T = {}

-- The validated FieldPlayerData record FieldRuntime already holds; the
-- profile is the only part the model projects.
local function playerData(overrides)
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

function T.demo_manifest_projects_to_the_exact_model_shape()
  local model = TrainerCardModel.new(playerData())
  -- The exact required shape: the three profile passthroughs and the five
  -- optional stats plus the signature, all nil. deepEqual also rejects any
  -- unexpected key, so a zero-valued optional field would fail here.
  Assert.deepEqual(model, {
    name = "GOLD",
    gender = 0,
    trainerId = 0,
    money = nil,
    playTime = nil,
    badges = nil,
    pokedexOwned = nil,
    stars = nil,
    signature = nil,
  })
end

function T.optional_card_fields_are_nil_never_zero()
  local model = TrainerCardModel.new(playerData())
  for _, field in ipairs({ "money", "playTime", "badges", "pokedexOwned", "stars", "signature" }) do
    Assert.isNil(model[field], "optional card field " .. field .. " must be nil, not a substituted value")
  end
end

function T.required_fields_never_nil_even_at_zero_values()
  local model = TrainerCardModel.new(playerData())
  Assert.notNil(model.name)
  Assert.notNil(model.gender)
  Assert.notNil(model.trainerId)
  Assert.equal(model.gender, 0)
  Assert.equal(model.trainerId, 0)
end

function T.maximum_width_and_boundary_values_are_preserved()
  local model = TrainerCardModel.new(playerData({
    profile = { name = "ABCDEFG", gender = 1, trainerId = 65535 },
  }))
  Assert.equal(model.name, "ABCDEFG")
  Assert.equal(model.gender, 1)
  Assert.equal(model.trainerId, 65535)
end

function T.semantic_values_only_no_display_formatting()
  local model = TrainerCardModel.new(playerData({
    profile = { name = "GOLD", gender = 0, trainerId = 12345 },
  }))
  -- The trainer id stays a raw integer; zero-padding and label text belong
  -- to the generated UI metadata/renderer.
  Assert.equal(type(model.trainerId), "number")
  Assert.equal(model.trainerId, 12345)
  Assert.equal(model.name, "GOLD")
  Assert.equal(model.signature, nil)
end

function T.model_is_a_fresh_copy_of_the_player_record()
  local data = playerData()
  local model = TrainerCardModel.new(data)
  model.name = "HIKARI"
  model.trainerId = 1
  Assert.equal(data.profile.name, "GOLD")
  Assert.equal(data.profile.trainerId, 0)
end

function T.missing_required_profile_fields_are_programming_invariants()
  local notTable = nil ---@type any
  Assert.throws(function()
    TrainerCardModel.new(notTable)
  end)
  Assert.throws(function()
    TrainerCardModel.new({ profile = "GOLD", options = playerData().options })
  end)
  Assert.throws(function()
    TrainerCardModel.new({ profile = { name = "GOLD", gender = 0 }, options = playerData().options })
  end)
  Assert.throws(function()
    TrainerCardModel.new({ profile = { name = "GOLD", trainerId = 0 }, options = playerData().options })
  end)
  Assert.throws(function()
    TrainerCardModel.new({ profile = { gender = 0, trainerId = 0 }, options = playerData().options })
  end)
  Assert.throws(function()
    TrainerCardModel.new({ options = playerData().options })
  end)
end

return { tests = T }
