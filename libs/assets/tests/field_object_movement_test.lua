-- Source-independent field-object movement profiles and their strict lookup contract.

local Assert = require("tests.support.Assert")
local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")

local T = {}

local DIRECTIONS = { "north", "south", "west", "east" }
local RANDOM_WAITS = { 16, 32, 48, 64 }

local function assertArray(actual, expected, label)
  Assert.deepEqual(actual, expected, label)
end

function T.catalog_contains_the_complete_semantic_profile_set()
  local names = {
    "stationary",
    "player",
    "look_around",
    "wander_around",
    "wander_north_south",
    "wander_west_east",
    "look_north_west",
    "look_north_east",
    "look_south_west",
    "look_south_east",
    "look_north_south_west",
    "look_north_south_east",
    "look_north_west_east",
    "look_south_west_east",
    "look_north",
    "look_south",
    "look_west",
    "look_east",
    "rotate_counterclockwise",
    "rotate_clockwise",
    "walk_back_and_forth",
    "walk_north_east_west_south",
    "walk_east_west_south_north",
    "walk_south_north_east_west",
    "walk_west_south_north_east",
    "walk_west_east_south_north",
    "walk_north_west_east_south",
    "walk_south_north_west_east",
    "walk_east_south_north_west",
    "walk_west_north_south_east",
    "walk_north_south_east_west",
    "walk_east_west_north_south",
    "walk_south_east_west_north",
    "walk_east_north_south_west",
    "walk_north_south_west_east",
    "walk_west_east_north_south",
    "walk_south_west_east_north",
    "walk_north_west_south_east",
    "walk_south_east_north_west",
    "walk_west_south_east_north",
    "walk_east_north_west_south",
    "walk_north_east_south_west",
    "walk_south_west_north_east",
    "walk_west_north_east_south",
    "walk_east_south_west_north",
    "look_north_south",
    "look_west_east",
    "vs_seeker_spin",
    "null_slot",
    "follow_player",
    "follow_partner",
    "disguise_snow",
    "disguise_sand",
    "disguise_rock",
    "disguise_grass",
    "follow_transition_a",
    "follow_transition_b",
  }
  Assert.equal(#names, 57)
  for _, name in ipairs(names) do
    Assert.isTrue(FieldObjectMovement.isType(name), name)
    Assert.notNil(FieldObjectMovement.require(name), name)
  end
  Assert.isFalse(FieldObjectMovement.isType("3"))
  Assert.throws(function()
    FieldObjectMovement.require("unknown")
  end)
end

function T.random_look_and_walk_profiles_have_source_wait_choices_and_directions()
  local expectations = {
    { name = "look_around", directions = DIRECTIONS, nearby = true },
    { name = "wander_around", directions = DIRECTIONS },
    { name = "wander_north_south", directions = { "north", "south" } },
    { name = "wander_west_east", directions = { "west", "east" } },
    { name = "look_north_west", directions = { "north", "west" }, nearby = true },
    { name = "look_north_east", directions = { "north", "east" }, nearby = true },
    { name = "look_south_west", directions = { "south", "west" }, nearby = true },
    { name = "look_south_east", directions = { "south", "east" }, nearby = true },
    { name = "look_north_south_west", directions = { "north", "south", "west" }, nearby = true },
    { name = "look_north_south_east", directions = { "north", "south", "east" }, nearby = true },
    { name = "look_north_west_east", directions = { "north", "west", "east" }, nearby = true },
    { name = "look_south_west_east", directions = { "south", "west", "east" }, nearby = true },
    { name = "look_north_south", directions = { "north", "south" }, nearby = true },
    { name = "look_west_east", directions = { "west", "east" }, nearby = true },
  }
  for _, expected in ipairs(expectations) do
    local profile = FieldObjectMovement.require(expected.name)
    Assert.equal(profile.kind, expected.name:find("look", 1, true) and "look" or "wander")
    assertArray(profile.directions, expected.directions, expected.name)
    assertArray(profile.waitChoices, RANDOM_WAITS, expected.name .. " waits")
    Assert.equal(profile.nearbyPlayerFacing, expected.nearby == true, expected.name .. " nearby")
  end
end

function T.fixed_rotation_and_pattern_profiles_preserve_ordered_behavior_facts()
  local fixed = {
    look_north = "north",
    look_south = "south",
    look_west = "west",
    look_east = "east",
  }
  for name, direction in pairs(fixed) do
    local profile = FieldObjectMovement.require(name)
    Assert.equal(profile.kind, "stationary")
    Assert.equal(profile.fixedFacing, direction)
  end

  Assert.deepEqual(FieldObjectMovement.require("rotate_counterclockwise"), {
    kind = "rotate",
    sequence = { "north", "west", "south", "east" },
    rotationInterval = 24,
    nearbyPlayerFacing = true,
  })
  Assert.deepEqual(FieldObjectMovement.require("rotate_clockwise"), {
    kind = "rotate",
    sequence = { "north", "east", "south", "west" },
    rotationInterval = 24,
    nearbyPlayerFacing = true,
  })

  local patterns = {
    { "north", "east", "west", "south" },
    { "east", "west", "south", "north" },
    { "south", "north", "east", "west" },
    { "west", "south", "north", "east" },
    { "west", "east", "south", "north" },
    { "north", "west", "east", "south" },
    { "south", "north", "west", "east" },
    { "east", "south", "north", "west" },
    { "west", "north", "south", "east" },
    { "north", "south", "east", "west" },
    { "east", "west", "north", "south" },
    { "south", "east", "west", "north" },
    { "east", "north", "south", "west" },
    { "north", "south", "west", "east" },
    { "west", "east", "north", "south" },
    { "south", "west", "east", "north" },
    { "north", "west", "south", "east" },
    { "south", "east", "north", "west" },
    { "west", "south", "east", "north" },
    { "east", "north", "west", "south" },
    { "north", "east", "south", "west" },
    { "south", "west", "north", "east" },
    { "west", "north", "east", "south" },
    { "east", "south", "west", "north" },
  }
  for index, sequence in ipairs(patterns) do
    local name = ({
      "walk_north_east_west_south",
      "walk_east_west_south_north",
      "walk_south_north_east_west",
      "walk_west_south_north_east",
      "walk_west_east_south_north",
      "walk_north_west_east_south",
      "walk_south_north_west_east",
      "walk_east_south_north_west",
      "walk_west_north_south_east",
      "walk_north_south_east_west",
      "walk_east_west_north_south",
      "walk_south_east_west_north",
      "walk_east_north_south_west",
      "walk_north_south_west_east",
      "walk_west_east_north_south",
      "walk_south_west_east_north",
      "walk_north_west_south_east",
      "walk_south_east_north_west",
      "walk_west_south_east_north",
      "walk_east_north_west_south",
      "walk_north_east_south_west",
      "walk_south_west_north_east",
      "walk_west_north_east_south",
      "walk_east_south_west_north",
    })[index]
    local profile = FieldObjectMovement.require(name)
    Assert.equal(profile.kind, "pattern", name)
    Assert.deepEqual(profile.sequence, sequence, name)
  end
  Assert.equal(FieldObjectMovement.require("walk_back_and_forth").kind, "shuttle")
  Assert.deepEqual(FieldObjectMovement.require("vs_seeker_spin"), {
    kind = "spin",
    spinInterval = 24,
    clockwiseSequence = { "north", "east", "south", "west" },
    counterclockwiseSequence = { "north", "west", "south", "east" },
  })
end

function T.special_profiles_are_classified_and_lookup_results_are_copy_safe()
  local special = {
    player = "player",
    null_slot = "null",
    follow_player = "follower",
    follow_partner = "partner",
    disguise_snow = "disguise",
    disguise_sand = "disguise",
    disguise_rock = "disguise",
    disguise_grass = "disguise",
    follow_transition_a = "follower_transition",
    follow_transition_b = "follower_transition",
  }
  for name, classification in pairs(special) do
    local profile = FieldObjectMovement.require(name)
    Assert.equal(profile.kind, "special", name)
    Assert.equal(profile.special, classification, name)
  end

  local first = FieldObjectMovement.require("look_around")
  first.directions[1] = "mutated"
  first.waitChoices[1] = 999
  local second = FieldObjectMovement.require("look_around")
  Assert.equal(second.directions[1], "north")
  Assert.equal(second.waitChoices[1], 16)
end

return { tests = T }
