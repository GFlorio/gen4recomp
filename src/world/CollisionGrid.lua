-- Wraps a PermissionGrid with the map cell's global tile origin so the runtime
-- can address tiles in either local (0..31 within the 32x32 cell) or global
-- (matrix-wide) coordinates. Blocking is exactly the permission grid's hard-
-- block bit (0x80); surface responses like 4 and 6 stay passable. Elm's Lab has
-- origin (0,0) so local == global there; New Bark will carry a nonzero origin.
-- Pure domain module (no love); the permission policy lives in PermissionGrid.

local CollisionGrid = {}
CollisionGrid.__index = CollisionGrid

function CollisionGrid.new(permissionGrid, opts)
  assert(permissionGrid, "CollisionGrid.new requires a permission grid")
  opts = opts or {}
  return setmetatable({
    grid = permissionGrid,
    worldOriginX = opts.worldOriginX or 0,
    worldOriginZ = opts.worldOriginZ or 0,
    width = permissionGrid.width,
    height = permissionGrid.height,
  }, CollisionGrid)
end

function CollisionGrid:globalToLocal(globalX, globalZ)
  return globalX - self.worldOriginX, globalZ - self.worldOriginZ
end

function CollisionGrid:localToGlobal(localX, localZ)
  return localX + self.worldOriginX, localZ + self.worldOriginZ
end

function CollisionGrid:containsLocal(localX, localZ)
  return self.grid:contains(localX, localZ)
end

-- The full permission record for a local tile (behavior/permission/hardBlocked/
-- terrainResponseId), for HUD/diagnostics.
function CollisionGrid:getLocal(localX, localZ)
  return self.grid:get(localX, localZ)
end

function CollisionGrid:isBlockedLocal(localX, localZ)
  return self.grid:isBlocked(localX, localZ)
end

function CollisionGrid:isBlockedGlobal(globalX, globalZ)
  local lx, lz = self:globalToLocal(globalX, globalZ)
  return self.grid:isBlocked(lx, lz)
end

return CollisionGrid
