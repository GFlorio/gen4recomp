-- Builds valid project-owned collision assets (G4CL) for cache and loader
-- fixtures. `blockedTiles` lists { x, z } tiles whose blocked flag is set;
-- every other tile is a passable zero cell.

local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")

local CollisionFixture = {}

function CollisionFixture.asset(width, height, blockedTiles)
  local cells = {}
  for z = 0, height - 1 do
    for x = 0, width - 1 do
      cells[z * width + x + 1] = { behavior = 0, terrainResponseId = 0, blocked = false }
    end
  end
  for _, tile in ipairs(blockedTiles or {}) do
    cells[tile.z * width + tile.x + 1].blocked = true
  end
  return CollisionGridAsset.encode({ width = width, height = height, cells = cells })
end

-- A decoded 32x32 grid with the given blocked tiles.
function CollisionFixture.grid32(blockedTiles)
  return assert(CollisionGridAsset.decode(CollisionFixture.asset(32, 32, blockedTiles)))
end

return CollisionFixture
