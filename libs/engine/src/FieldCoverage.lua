-- Owns the bounded resident physical-cell window used by outdoor maps. A
-- recenter stages all missing cells and the composite region before replacing
-- the active window, so acquisition failures cannot damage the current world.

local CollisionGrid = require("libs.engine.src.CollisionGrid")
local FieldRegion = require("libs.engine.src.FieldRegion")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local FieldCellCache = require("libs.assets.src.FieldCellCache")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local Matrix4 = require("libs.math.src.Matrix4")
local BillboardTransform = require("libs.engine.src.BillboardTransform")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

---@class PhysicalProbeContext
---@field currentCellKey string
---@field currentSourceSurfaceId integer
---@field currentY number
---@field fromFieldX integer
---@field fromFieldZ integer
---@class FieldCoverage
---@field cacheFs CacheFs?
---@field index table
---@field matrixMemberId integer
---@field loadCell fun(descriptor: table): table
---@field presentationLoader fun(runtime: table, descriptor: table): table?
---@field cells table<string, table>
---@field anchorX integer
---@field anchorZ integer
---@field origin { x: number, y: number, z: number }
---@field region table
---@field terrainDependencyHash string
---@field released boolean
local FieldCoverage = {}
FieldCoverage.__index = FieldCoverage

local function key(x, z)
  return string.format("%d:%d", x, z)
end

local function desired(x, z)
  local result = {}
  for _, dz in ipairs({ 0, -1, 1 }) do
    for dx = -1, 1 do
      result[#result + 1] = { x = x + dx, z = z + dz }
    end
  end
  return result
end

local function cellOrigin(runtime, descriptor)
  local origin = assert(runtime.origin or descriptor.origin, "field cell normalized origin is missing")
  assert(type(origin.x) == "number" and type(origin.y) == "number" and type(origin.z) == "number")
  return { x = origin.x, y = origin.y, z = origin.z }
end

local function ownPresentation(runtime, presentation)
  local releaseRuntime = runtime.release
  local released = false
  runtime.presentation = presentation
  runtime.release = function(self)
    if released then
      return
    end
    released = true
    if presentation and presentation ~= self and presentation.release then
      presentation:release()
    end
    if releaseRuntime then
      releaseRuntime(self)
    end
  end
  return runtime
end

local function runtimeFromDescriptor(self, descriptor, acquirePresentation)
  local runtime
  if self.loadCell then
    runtime = self.loadCell(descriptor)
  else
    local cell = assert(self.cacheFs:loadLua(descriptor.file), "field cell descriptor is missing")
    local collisionBytes = assert(self.cacheFs:read(cell.collision.file), "field cell collision is missing")
    local collision = assert(CollisionGridAsset.decode(collisionBytes))
    local terrainArtifact = assert(self.cacheFs:loadLua(cell.terrain.file), "field cell terrain is missing")
    runtime = {
      key = key(cell.x, cell.z),
      x = cell.x,
      z = cell.z,
      altitude = cell.altitude,
      origin = cell.origin,
      collision = CollisionGrid.new(collision),
      terrain = TerrainSurface.new(terrainArtifact),
      descriptor = cell,
      release = function() end,
    }
  end
  runtime = assert(runtime, "field cell loader returned no runtime")
  runtime.key = runtime.key or key(descriptor.x, descriptor.z)
  runtime.x, runtime.z = runtime.x or descriptor.x, runtime.z or descriptor.z
  runtime.altitude = runtime.altitude or descriptor.altitude
  runtime.origin = cellOrigin(runtime, descriptor)
  local presentationDescriptor = runtime.descriptor or descriptor
  local presentation
  if acquirePresentation and self.presentationLoader then
    local ok, result = pcall(self.presentationLoader, runtime, presentationDescriptor)
    if not ok then
      if runtime.release then
        runtime:release()
      end
      error(result, 0)
    end
    presentation = result
  else
    presentation = runtime.presentation
  end
  return ownPresentation(runtime, presentation)
end

local function buildRegion(cells, anchor)
  local central = assert(cells[key(anchor.x, anchor.z)], "coverage anchor cell is missing")
  local neighbors = {}
  local centralOrigin = assert(central.origin, "coverage cell origin is missing")
  for cellKey, cell in pairs(cells) do
    if cellKey ~= central.key then
      local origin = assert(cell.origin, "coverage cell origin is missing")
      neighbors[#neighbors + 1] = {
        key = cell.key,
        offsetTilesX = origin.x - centralOrigin.x,
        offsetTilesY = origin.y - centralOrigin.y,
        offsetTilesZ = origin.z - centralOrigin.z,
        collision = cell.collision,
        terrain = cell.terrain,
      }
    end
  end
  table.sort(neighbors, function(a, b)
    return a.key < b.key
  end)
  return FieldRegion.new(central.collision, central.terrain, neighbors, central.key, 1)
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
    presentationLoader = options.presentationLoader,
    cells = {},
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
          local runtime = assert(runtimeFromDescriptor(self, descriptor, true))
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
      origin = assert(staged[key(anchorX, anchorZ)].origin),
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
  self.origin = candidate.origin
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
    physicalOrigin = { x = self.origin.x, y = self.origin.y, z = self.origin.z },
    probeCount = 0,
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

function FieldCoverage:sourceSurface(cellKey, sourceSurfaceId)
  return self.region:sourceSurface(cellKey, sourceSurfaceId)
end

-- Project a stable physical surface into the current resident frame. The
-- returned world position is derived from the current composite terrain and
-- normalized physical origin; callers must not retain it as semantic state.
---@param fieldX integer
---@param fieldZ integer
---@param cellKey string
---@param sourceSurfaceId integer
---@return { fieldX: integer, fieldZ: integer, cellKey: string, sourceSurfaceId: integer, surfaceId: integer, localX: number, localZ: number, worldX: number, worldY: number, worldZ: number }
function FieldCoverage:project(fieldX, fieldZ, cellKey, sourceSurfaceId)
  assert(type(fieldX) == "number" and fieldX % 1 == 0, "projected fieldX must be an integer")
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0, "projected fieldZ must be an integer")
  assert(type(cellKey) == "string", "projected cell key is required")
  assert(type(sourceSurfaceId) == "number", "projected source surface is required")
  local surfaceId =
    assert(self:sourceSurface(cellKey, sourceSurfaceId), "projected source surface is absent from coverage")
  local localX = fieldX - self.origin.x
  local localZ = fieldZ - self.origin.z
  local centerX, centerZ = localX + 0.5, localZ + 0.5
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
    surfaceId = surfaceId,
    localX = localX,
    localZ = localZ,
    worldX = centerX,
    worldY = self.region.terrain:sampleHeight(surfaceId, centerX, centerZ),
    worldZ = centerZ,
  }
end

local function presentationDraws(presentation)
  if not presentation then
    return {}
  end
  if type(presentation.parts) == "table" then
    return presentation.parts
  end
  local result = {}
  for _, field in ipairs({ "mapDraws", "staticBuildingDraws", "animatedBuildingDraws", "draws" }) do
    local draws = presentation[field]
    if type(draws) == "table" then
      for _, draw in ipairs(draws) do
        result[#result + 1] = draw
      end
    end
  end
  if #result == 0 and presentation.cellKey then
    result[1] = presentation
  end
  return result
end

local function translatedPart(part, cell, origin)
  local result = {}
  for field, value in pairs(part) do
    result[field] = value
  end
  result.cellKey = cell.key
  result.translation = {
    x = cell.origin.x - origin.x,
    y = cell.origin.y - origin.y,
    z = cell.origin.z - origin.z,
  }
  if part.transform then
    result.transform = Matrix4.multiply(
      Matrix4.translate(result.translation.x, result.translation.y, result.translation.z),
      part.transform
    )
  end
  if part.billboardBase then
    result.billboardBase = Matrix4.multiply(
      Matrix4.translate(result.translation.x, result.translation.y, result.translation.z),
      part.billboardBase
    )
    result.billboardCenter, result.billboardScale = BillboardTransform.components(result.billboardBase)
  end
  return result
end

function FieldCoverage:worldParts()
  local result = {}
  local keys = {}
  for cellKey in pairs(self.cells) do
    keys[#keys + 1] = cellKey
  end
  table.sort(keys)
  for _, cellKey in ipairs(keys) do
    local cell = self.cells[cellKey]
    for _, part in ipairs(presentationDraws(cell.presentation)) do
      result[#result + 1] = translatedPart(part, cell, self.origin)
    end
  end
  return result
end

function FieldCoverage:updateAnimated()
  assert(not self.released, "coverage is released")
  local keys = {}
  for cellKey in pairs(self.cells) do
    keys[#keys + 1] = cellKey
  end
  table.sort(keys)
  for _, cellKey in ipairs(keys) do
    local presentation = self.cells[cellKey].presentation
    if presentation and presentation.updateAnimated then
      presentation:updateAnimated()
    end
  end
end

-- Read-only generated-cache lookup used by route planning before a committed
-- step can recenter the resident window. It creates no resident ownership and
-- releases the temporary CPU cell immediately.
local function terrainFor(runtime)
  if runtime.terrain.candidatesAt and runtime.terrain.plate and runtime.terrain.sampleHeight then
    return runtime.terrain
  end
  return TerrainSurface.new(runtime.terrain)
end

local function resolveProbe(self, runtime, sourceRuntime, fieldX, fieldZ, context)
  local terrain
  local localX, localZ
  local region
  if context then
    local source = assert(sourceRuntime, "probe source cell runtime is missing")
    local sourceOrigin = assert(source.origin, "probe source cell origin is missing")
    if runtime == source and self.cells[context.currentCellKey] then
      region = self.region
      localX = fieldX - self.origin.x + 0.5
      localZ = fieldZ - self.origin.z + 0.5
      local fromX = context.fromFieldX - self.origin.x + 0.5
      local fromZ = context.fromFieldZ - self.origin.z + 0.5
      terrain = region.terrain
      local currentSurfaceId = assert(
        region:sourceSurface(context.currentCellKey, context.currentSourceSurfaceId),
        "probe source surface is absent from current coverage"
      )
      local sample = SurfaceResolver.new(terrain):resolve({
        localX = localX,
        localZ = localZ,
        currentSurfaceId = currentSurfaceId,
        currentY = context.currentY,
        crossing = { fromX = fromX, fromZ = fromZ, toX = localX, toZ = localZ },
      })
      return sample, terrain, region, 0
    end

    local destinationOrigin = assert(runtime.origin, "probe destination cell origin is missing")
    local neighbors = {}
    if runtime ~= source then
      neighbors[1] = {
        key = runtime.key,
        offsetTilesX = destinationOrigin.x - sourceOrigin.x,
        offsetTilesY = destinationOrigin.y - sourceOrigin.y,
        offsetTilesZ = destinationOrigin.z - sourceOrigin.z,
        collision = runtime.collision,
        terrain = runtime.terrain,
      }
    end
    region = FieldRegion.new(source.collision, source.terrain, neighbors, source.key, 1)
    local currentSurfaceId = assert(
      region:sourceSurface(context.currentCellKey, context.currentSourceSurfaceId),
      "probe source surface is absent from temporary region"
    )
    local fromX = context.fromFieldX - sourceOrigin.x + 0.5
    local fromZ = context.fromFieldZ - sourceOrigin.z + 0.5
    local destinationX = fieldX - sourceOrigin.x + 0.5
    local destinationZ = fieldZ - sourceOrigin.z + 0.5
    local frameOffsetY = sourceOrigin.y - self.origin.y
    local sample = SurfaceResolver.new(region.terrain):resolve({
      localX = destinationX,
      localZ = destinationZ,
      currentSurfaceId = currentSurfaceId,
      currentY = context.currentY - frameOffsetY,
      crossing = { fromX = fromX, fromZ = fromZ, toX = destinationX, toZ = destinationZ },
    })
    return sample, region.terrain, region, frameOffsetY
  end

  local destinationX = fieldX - math.floor(fieldX / 32) * 32 + 0.5
  local destinationZ = fieldZ - math.floor(fieldZ / 32) * 32 + 0.5
  terrain = terrainFor(runtime)
  local sample = SurfaceResolver.new(terrain):resolve({ localX = destinationX, localZ = destinationZ })
  return sample, terrain, nil, 0
end

local function cellCoordinates(cellKey)
  local x, z = string.match(cellKey, "^(-?%d+):(-?%d+)$")
  assert(x and z, "physical cell key must contain integer coordinates")
  return assert(tonumber(x)), assert(tonumber(z))
end

local function acquireProbeCell(self, cellKey)
  local runtime = self.cells[cellKey]
  if runtime then
    return runtime, false
  end
  local cellX, cellZ = cellCoordinates(cellKey)
  local descriptor = assert(
    FieldCellCache.find(self.index, self.matrixMemberId, cellX, cellZ),
    "probe source cell descriptor is missing"
  )
  return assert(runtimeFromDescriptor(self, descriptor, false)), true
end

---@param fieldX integer
---@param fieldZ integer
---@param context PhysicalProbeContext?
---@return table?
function FieldCoverage:probe(fieldX, fieldZ, context)
  assert(type(fieldX) == "number" and fieldX % 1 == 0, "probed fieldX must be an integer")
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0, "probed fieldZ must be an integer")
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, cellX, cellZ)
  if not descriptor then
    return {
      cellKey = key(cellX, cellZ),
      collision = { blocked = true, cellKey = key(cellX, cellZ) },
      sourceSurfaceId = nil,
    }
  end
  local cellKey = key(cellX, cellZ)
  local runtime = self.cells[cellKey]
  local temporary = runtime == nil
  local sourceRuntime
  local sourceTemporary = false
  local localX, localZ = fieldX - cellX * 32, fieldZ - cellZ * 32
  local ok, result = pcall(function()
    if context then
      if context.currentCellKey == cellKey then
        if runtime == nil then
          runtime, temporary = acquireProbeCell(self, cellKey)
        end
        sourceRuntime = runtime
      else
        sourceRuntime, sourceTemporary = acquireProbeCell(self, context.currentCellKey)
      end
    end
    runtime = runtime or assert(runtimeFromDescriptor(self, descriptor, false))
    local collision = runtime.collision:getLocal(localX, localZ)
    collision.cellKey = cellKey
    local sample, terrain, region, frameOffsetY = resolveProbe(self, runtime, sourceRuntime, fieldX, fieldZ, context)
    local plate = assert(terrain:plate(sample.surfaceId), "probed terrain surface is missing")
    return {
      cellKey = plate.cellKey or cellKey,
      collision = collision,
      sourceSurfaceId = plate.sourceSurfaceId ~= nil and plate.sourceSurfaceId or plate.id,
      surfaceId = context and region == self.region and sample.surfaceId or nil,
      worldY = sample.worldY + frameOffsetY,
    }
  end)
  if temporary and runtime.release then
    runtime:release()
  end
  if sourceTemporary and sourceRuntime.release then
    sourceRuntime:release()
  end
  if not ok then
    if SurfaceResolver.isStepRejection(result) then
      return nil
    end
    error(result, 0)
  end
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
end

return FieldCoverage
