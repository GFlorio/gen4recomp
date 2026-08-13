-- MetatileBehavior: the TILE_BEHAVIOR_* metatile behavior byte vocabulary
-- (pret/pokeheartgold include/constants/metatile_behavior.h, sequential
-- enum, NONE = 255) plus the pure behavior predicates the field runtime
-- shares. The vocabulary lives below gameplay trigger policy so door-tile
-- enumeration and door lookup never depend on the whole TransitionTrigger
-- module. Pure domain module (no love).

local MetatileBehavior = {}

-- TILE_BEHAVIOR_* warp-relevant values (pokeheartgold metatile_behavior.h).
MetatileBehavior.BEHAVIOR = {
  LADDER_NORTH = 60,
  LADDER_SOUTH = 61,
  LADDER_DOWN = 62,
  WARP_STAIRS_EAST = 94,
  WARP_STAIRS_WEST = 95,
  WARP_ENTRANCE_EAST = 98,
  WARP_ENTRANCE_WEST = 99,
  WARP_ENTRANCE_NORTH = 100,
  WARP_ENTRANCE_SOUTH = 101,
  WARP_PANEL = 103,
  DOOR = 105,
  ESCALATOR_FLIP_FACE = 106,
  ESCALATOR = 107,
  WARP_EAST = 108,
  WARP_WEST = 109,
  WARP_NORTH = 110,
  WARP_SOUTH = 111,
}

-- Whether a behavior byte is the DOOR metatile (behavior 105).
---@param behavior integer?
---@return boolean
function MetatileBehavior.isDoor(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.DOOR
end

return MetatileBehavior
