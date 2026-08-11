-- DoorTiles: the DOOR-kind (behavior 105) tiles of a scene's permission
-- cell, as local cell indices. The scene assembly (MapSceneLoader) and the
-- fixture door suites enumerate door ownership over exactly this list, so
-- the door-tile contract -- which tiles count, and in which coordinate
-- space -- lives here once instead of being mirrored. Pure domain module
-- (no love).

local FieldGrid = require("libs.engine.src.FieldGrid")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")

local DoorTiles = {}

-- The door tiles of a CollisionGrid-shaped grid (anything with
-- getLocal(x, z) -> { behavior }), in enumeration order (x-major, z-major).
-- The grid must be the scene's 32x32 cell; the tiles are local indices, the
-- space MapProps keys its precomputed door index with.
---@param grid table -- CollisionGrid-shaped: getLocal(x, z) -> { behavior: integer|nil }
---@return { x: integer, z: integer }[]
function DoorTiles.fromGrid(grid)
  local out = {}
  for localX = 0, FieldGrid.CELL_TILES - 1 do
    for localZ = 0, FieldGrid.CELL_TILES - 1 do
      local behavior = grid:getLocal(localX, localZ).behavior
      local classification = behavior and TransitionTrigger.classify(behavior)
      if classification and classification.kind == "door" then
        out[#out + 1] = { x = localX, z = localZ }
      end
    end
  end
  return out
end

return DoorTiles
