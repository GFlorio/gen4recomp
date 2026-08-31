-- HGSS source movement selectors normalized into the semantic field-object contract.

local Assert = require("tests.support.Assert")
local FieldObjectMovement = require("libs.assets.src.FieldObjectMovement")
local HgssObjectMovement = require("romdump.src.digest.HgssObjectMovement")

local T = {}

local EXPECTED = {
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
  "null_slot",
  "follow_player",
  "vs_seeker_spin",
  "follow_partner",
  "disguise_snow",
  "disguise_sand",
  "disguise_rock",
  "disguise_grass",
  "follow_transition_a",
  "follow_transition_b",
}

function T.every_source_slot_maps_to_one_catalog_type()
  Assert.equal(#EXPECTED, 57)
  for rawMovement = 0, 56 do
    local movementType = HgssObjectMovement.semanticType(rawMovement)
    Assert.equal(movementType, EXPECTED[rawMovement + 1], "source movement " .. rawMovement)
    Assert.isTrue(FieldObjectMovement.isType(movementType), movementType)
    Assert.notNil(FieldObjectMovement.require(movementType), movementType)
  end
end

function T.invalid_source_selectors_fail_without_a_stationary_fallback()
  for _, value in ipairs({ -1, 57, 1.5, "3" }) do
    Assert.throws(function()
      HgssObjectMovement.semanticType(value)
    end, "invalid source movement must fail")
  end
  Assert.throws(function()
    HgssObjectMovement.semanticType(nil)
  end, "nil source movement must fail")
end

function T.nearby_player_facing_matches_the_source_eligibility_set()
  local eligible = {
    [2] = true,
    [6] = true,
    [7] = true,
    [8] = true,
    [9] = true,
    [10] = true,
    [11] = true,
    [12] = true,
    [13] = true,
    [18] = true,
    [19] = true,
    [45] = true,
    [46] = true,
  }
  for rawMovement = 0, 56 do
    local profile = FieldObjectMovement.require(HgssObjectMovement.semanticType(rawMovement))
    Assert.equal(profile.nearbyPlayerFacing == true, eligible[rawMovement] == true, "source movement " .. rawMovement)
  end
end

return { tests = T }
