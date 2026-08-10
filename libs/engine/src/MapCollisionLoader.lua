-- Loads the simulation-only map scene facts needed by FieldRuntime. Rendering
-- turns the same derived scene into GPU resources later; this loader never
-- touches LÖVE graphics.

local CollisionGrid = require("libs.engine.src.CollisionGrid")
local PermissionGrid = require("libs.assets.src.PermissionGrid")

local MapCollisionLoader = {}

---@param cacheFs table
---@param scene table
---@return table
function MapCollisionLoader.load(cacheFs, scene)
  local bytes = assert(cacheFs:read(scene.collision.file), "missing permissions")
  local permissions = assert(PermissionGrid.decode(bytes, scene.mapSymbol))
  local collision = CollisionGrid.new(permissions, {
    worldOriginX = scene.matrix.worldOriginX,
    worldOriginZ = scene.matrix.worldOriginZ,
  })
  return {
    collision = collision,
    release = function() end,
  }
end

return MapCollisionLoader
