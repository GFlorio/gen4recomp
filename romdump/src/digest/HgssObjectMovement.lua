-- HGSS object movement selector normalization, based on pret/pokeheartgold
-- 0985e8718df4f25e64d6507d89c0c97c0d288981 src/map_object.c and its movement
-- controller tables in asm/unk_02061284.s and asm/unk_data_020FCBD8.s.

local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")

local HgssObjectMovement = {}

local SOURCE_TYPES = {
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

for rawMovement = 0, 56 do
  assert(FieldObjectMovement.isType(SOURCE_TYPES[rawMovement + 1]), "source movement has no semantic profile")
end

---@param rawMovement unknown
---@return string
function HgssObjectMovement.semanticType(rawMovement)
  assert(
    type(rawMovement) == "number" and rawMovement == math.floor(rawMovement) and rawMovement >= 0 and rawMovement <= 56,
    "raw object movement must be an integer in 0..56, got " .. tostring(rawMovement)
  )
  return SOURCE_TYPES[rawMovement + 1]
end

return HgssObjectMovement
