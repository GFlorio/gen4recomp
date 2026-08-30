-- MetatileBehavior: the TILE_BEHAVIOR_* metatile behavior byte vocabulary
-- (pret/pokeheartgold include/constants/metatile_behavior.h, sequential
-- enum, NONE = 255) plus the pure behavior predicates the field runtime
-- shares. The vocabulary lives below gameplay trigger policy so door-tile
-- enumeration and door lookup never depend on the whole TransitionTrigger
-- module. Pure domain module (no love).

local MetatileBehavior = {}

local LEDGE_DIRECTIONS = {}

-- TILE_BEHAVIOR_* warp-relevant values (pokeheartgold metatile_behavior.h).
MetatileBehavior.BEHAVIOR = {
  TALL_GRASS = 2,
  VERY_TALL_GRASS = 3,
  RIVER_WATER = 16,
  WHIRLPOOL = 17,
  WATERFALL = 19,
  SEA_WATER = 21,
  JUMP_EAST = 56,
  JUMP_WEST = 57,
  JUMP_NORTH = 58,
  JUMP_SOUTH = 59,
  ROCK_CLIMB_NORTH_SOUTH = 75,
  ROCK_CLIMB_EAST_WEST = 76,
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

LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_EAST] = "east"
LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_WEST] = "west"
LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_NORTH] = "north"
LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_SOUTH] = "south"

-- Whether a behavior byte is the DOOR metatile (behavior 105).
---@param behavior integer?
---@return boolean
function MetatileBehavior.isDoor(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.DOOR
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.isSurfableWater(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.RIVER_WATER or behavior == MetatileBehavior.BEHAVIOR.SEA_WATER
end

---@param behavior integer?
---@return string?
function MetatileBehavior.fieldAction(behavior)
  if MetatileBehavior.isSurfableWater(behavior) then
    return "surf"
  elseif behavior == MetatileBehavior.BEHAVIOR.WATERFALL then
    return "waterfall"
  elseif behavior == MetatileBehavior.BEHAVIOR.WHIRLPOOL then
    return "whirlpool"
  elseif
    behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_EAST_WEST
    or behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH
  then
    return "rock_climb"
  end
  return nil
end

---@param behavior integer?
---@return string?
function MetatileBehavior.ledgeDirection(behavior)
  return LEDGE_DIRECTIONS[behavior]
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.isTallGrass(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.TALL_GRASS
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.isVeryTallGrass(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.VERY_TALL_GRASS
end

local WARP_ENTRANCE_DIRECTIONS = {
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_NORTH] = "north",
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_SOUTH] = "south",
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_WEST] = "west",
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST] = "east",
}

---@param behavior integer?
---@return string?
function MetatileBehavior.warpEntranceDirection(behavior)
  return WARP_ENTRANCE_DIRECTIONS[behavior]
end

return MetatileBehavior
