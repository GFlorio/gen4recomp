-- Wraps a decoded collision grid asset with the map cell's global tile origin
-- so the runtime can address tiles in either local (0..width-1 within the
-- cell) or global (matrix-wide) coordinates. Blocking is exactly the asset's
-- semantic `blocked` cell flag; behavior and terrainResponseId are opaque
-- cell fields the runtime carries for HUD/diagnostics. The decoded asset is
-- immutable generated data: getLocal returns a copy so no consumer can mutate
-- a shared cell. Pure domain module (no love); the G4CL binary format lives in
-- CollisionGridAsset and the HGSS source packing lives in romdump.

local CollisionGrid = {}
CollisionGrid.__index = CollisionGrid

---@class CollisionGrid
---@field grid { width: integer, height: integer, cells: table[] }
---@field worldOriginX integer
---@field worldOriginZ integer
---@field width integer
---@field height integer
---@field localToGlobal fun(self: CollisionGrid, localX: number, localZ: number): number, number
---@field globalToLocal fun(self: CollisionGrid, globalX: number, globalZ: number): number, number
---@field getLocal fun(self: CollisionGrid, localX: integer, localZ: integer): table
---@field containsLocal fun(self: CollisionGrid, localX: number, localZ: number): boolean
---@field isBlockedLocal fun(self: CollisionGrid, localX: number, localZ: number): boolean
---@field isBlockedGlobal fun(self: CollisionGrid, globalX: number, globalZ: number): boolean

local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

---@param collisionGrid { width: integer, height: integer, cells: table[] }
---@param opts { worldOriginX?: integer, worldOriginZ?: integer }|nil
---@return CollisionGrid
function CollisionGrid.new(collisionGrid, opts)
  assert(collisionGrid and type(collisionGrid.cells) == "table", "CollisionGrid.new requires a decoded collision grid")
  opts = opts or {}
  local instance = setmetatable({
    grid = collisionGrid,
    worldOriginX = opts.worldOriginX or 0,
    worldOriginZ = opts.worldOriginZ or 0,
    width = collisionGrid.width,
    height = collisionGrid.height,
  }, CollisionGrid)
  return instance --[[@as CollisionGrid]]
end

function CollisionGrid:globalToLocal(globalX, globalZ)
  return globalX - self.worldOriginX, globalZ - self.worldOriginZ
end

function CollisionGrid:localToGlobal(localX, localZ)
  return localX + self.worldOriginX, localZ + self.worldOriginZ
end

-- Cell coordinates are finite integers: a fractional coordinate would
-- otherwise read the shifted neighbouring cell.
function CollisionGrid:containsLocal(localX, localZ)
  return finiteInteger(localX)
    and finiteInteger(localZ)
    and localX >= 0
    and localZ >= 0
    and localX < self.width
    and localZ < self.height
end

-- The full cell record (behavior/terrainResponseId/blocked) for a local tile,
-- copied so callers cannot mutate the shared decoded grid.
function CollisionGrid:getLocal(localX, localZ)
  assert(self:containsLocal(localX, localZ), "local tile outside collision grid")
  local cell = self.grid.cells[localZ * self.width + localX + 1]
  return {
    behavior = cell.behavior,
    terrainResponseId = cell.terrainResponseId,
    blocked = cell.blocked,
  }
end

function CollisionGrid:isBlockedLocal(localX, localZ)
  assert(self:containsLocal(localX, localZ), "local tile outside collision grid")
  return self.grid.cells[localZ * self.width + localX + 1].blocked == true
end

function CollisionGrid:isBlockedGlobal(globalX, globalZ)
  local lx, lz = self:globalToLocal(globalX, globalZ)
  return self:isBlockedLocal(lx, lz)
end

return CollisionGrid
