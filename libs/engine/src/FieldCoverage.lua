-- Owns the bounded resident physical-cell window used by outdoor maps. A
-- recenter stages all missing cells and the composite region before replacing
-- the active window, so acquisition failures cannot damage the current world.

local CollisionGrid = require("libs.engine.src.CollisionGrid")
local FieldRegion = require("libs.engine.src.FieldRegion")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local FieldCellCache = require("libs.assets.src.FieldCellCache")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")

---@class FieldCoverage
---@field cacheFs CacheFs?
---@field index table
---@field matrixMemberId integer
---@field loadCell fun(descriptor: table): table
---@field cells table<string, table>
---@field anchorX integer
---@field anchorZ integer
---@field region table
---@field terrainDependencyHash string
---@field released boolean
---@field probes table<string, table>
local FieldCoverage = {}
FieldCoverage.__index = FieldCoverage

local function key(x, z)
  return string.format("%d:%d", x, z)
end

local function desired(x, z)
  local result = {}
  for dz = -1, 1 do
    for dx = -1, 1 do
      result[#result + 1] = { x = x + dx, z = z + dz }
    end
  end
  return result
end

local function runtimeFromDescriptor(self, descriptor)
  if self.loadCell then
    return self.loadCell(descriptor)
  end
  local cell = assert(self.cacheFs:loadLua(descriptor.file), "field cell descriptor is missing")
  local collisionBytes = assert(self.cacheFs:read(cell.collision.file), "field cell collision is missing")
  local collision = assert(CollisionGridAsset.decode(collisionBytes))
  local terrainArtifact = assert(self.cacheFs:loadLua(cell.terrain.file), "field cell terrain is missing")
  return {
    key = key(cell.x, cell.z),
    x = cell.x,
    z = cell.z,
    altitude = cell.altitude,
    collision = CollisionGrid.new(collision),
    terrain = TerrainSurface.new(terrainArtifact),
    descriptor = cell,
    release = function() end,
  }
end

local function buildRegion(cells, anchor)
  local central = assert(cells[key(anchor.x, anchor.z)], "coverage anchor cell is missing")
  local neighbors = {}
  for cellKey, cell in pairs(cells) do
    if cellKey ~= central.key then
      neighbors[#neighbors + 1] = {
        key = cell.key,
        offsetTilesX = (cell.x - anchor.x) * 32,
        offsetTilesY = (cell.altitude - central.altitude) * 0.5,
        offsetTilesZ = (cell.z - anchor.z) * 32,
        collision = cell.collision,
        terrain = cell.terrain,
      }
    end
  end
  table.sort(neighbors, function(a, b)
    return a.key < b.key
  end)
  return FieldRegion.new(central.collision, central.terrain, neighbors, central.key)
end

function FieldCoverage.new(options)
  assert(type(options) == "table", "FieldCoverage options required")
  assert(type(options.matrixMemberId) == "number", "field cell matrix member required")
  assert(options.index or options.cacheFs, "field cell cache required")
  local self = setmetatable({
    cacheFs = options.cacheFs,
    index = options.index or FieldCellCache.loadIndex(options.cacheFs),
    matrixMemberId = options.matrixMemberId,
    loadCell = options.loadCell,
    cells = {},
    probes = {},
    released = false,
  }, FieldCoverage)
  self:recenter(options.anchorX, options.anchorZ)
  return self
end

function FieldCoverage:recenter(anchorX, anchorZ)
  assert(not self.released, "coverage is released")
  assert(type(anchorX) == "number" and anchorX % 1 == 0 and type(anchorZ) == "number" and anchorZ % 1 == 0)
  local staged, acquired = {}, {}
  local candidate
  local ok, err = pcall(function()
    for _, position in ipairs(desired(anchorX, anchorZ)) do
      local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, position.x, position.z)
      if descriptor then
        local cellKey = key(position.x, position.z)
        local existing = self.cells[cellKey]
        if existing then
          staged[cellKey] = existing
        else
          local runtime = assert(runtimeFromDescriptor(self, descriptor))
          runtime.key = runtime.key or cellKey
          runtime.x, runtime.z = position.x, position.z
          runtime.altitude = runtime.altitude or descriptor.altitude
          staged[cellKey] = runtime
          acquired[#acquired + 1] = runtime
        end
      end
    end
    assert(staged[key(anchorX, anchorZ)], "coverage anchor is not a generated cell")
    candidate = {
      anchorX = anchorX,
      anchorZ = anchorZ,
      cells = staged,
      region = buildRegion(staged, { x = anchorX, z = anchorZ }),
    }
  end)
  if not ok then
    for _, cell in ipairs(acquired) do
      if cell.release then
        cell:release()
      end
    end
    error(err, 0)
  end
  candidate = assert(candidate)
  local old = self.cells
  self.cells = candidate.cells
  self.anchorX, self.anchorZ = candidate.anchorX, candidate.anchorZ
  self.region = candidate.region
  self.terrainDependencyHash = self:_dependencyIdentity()
  for cellKey, cell in pairs(old) do
    if not self.cells[cellKey] and cell.release then
      cell:release()
    end
  end
  return self
end

function FieldCoverage:_dependencyIdentity()
  local keys = {}
  for cellKey, cell in pairs(self.cells) do
    keys[#keys + 1] = cellKey .. ":" .. tostring(cell.descriptor and cell.descriptor.terrain.file or "runtime")
  end
  table.sort(keys)
  return table.concat(
    { "g4-coverage-v1", self.matrixMemberId, self.anchorX, self.anchorZ, table.concat(keys, "|") },
    "|"
  )
end

function FieldCoverage:status()
  local resident = {}
  for cellKey in pairs(self.cells) do
    resident[#resident + 1] = cellKey
  end
  table.sort(resident)
  return {
    matrixMemberId = self.matrixMemberId,
    anchorX = self.anchorX,
    anchorZ = self.anchorZ,
    residentCellKeys = resident,
    residentCount = #resident,
    terrainDependencyHash = self.terrainDependencyHash,
  }
end

function FieldCoverage:containsGlobal(fieldX, fieldZ)
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  return self.cells[key(cellX, cellZ)] ~= nil
end

---@return table
function FieldCoverage:currentCell()
  return assert(self.cells[key(self.anchorX, self.anchorZ)], "coverage anchor cell is missing")
end

---@param fieldX integer
---@param fieldZ integer
---@return integer?
function FieldCoverage:mapHeaderAt(fieldX, fieldZ)
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  local cell = self.cells[key(cellX, cellZ)]
  if cell then
    return cell.mapHeaderId or (cell.descriptor and cell.descriptor.mapHeaderId)
  end
  local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, cellX, cellZ)
  return descriptor and descriptor.mapHeaderId or nil
end

-- Read-only generated-cache lookup used by route planning before a committed
-- step can recenter the resident window. It creates no resident ownership and
-- releases the temporary CPU cell immediately.
function FieldCoverage:probe(fieldX, fieldZ)
  local probeKey = string.format("%d:%d", fieldX, fieldZ)
  if self.probes[probeKey] then
    return self.probes[probeKey]
  end
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, cellX, cellZ)
  if not descriptor then
    return nil
  end
  local runtime = assert(runtimeFromDescriptor(self, descriptor))
  local localX, localZ = fieldX - cellX * 32, fieldZ - cellZ * 32
  local collision = runtime.collision:getLocal(localX, localZ)
  local candidates = runtime.terrain:candidatesAt(localX + 0.5, localZ + 0.5)
  local plate = candidates[1]
  if runtime.release then
    runtime:release()
  end
  if not plate then
    return nil
  end
  local result = {
    collision = collision,
    surfaceId = plate.id,
    worldY = (plate.distance - plate.normal.x * (localX + 0.5) - plate.normal.z * (localZ + 0.5)) / plate.normal.y,
  }
  self.probes[probeKey] = result
  return result
end

function FieldCoverage:release()
  if self.released then
    return
  end
  self.released = true
  for _, cell in pairs(self.cells) do
    if cell.release then
      cell:release()
    end
  end
  self.cells = {}
  self.probes = {}
end

return FieldCoverage
