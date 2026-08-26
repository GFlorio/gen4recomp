-- Owns logical field-map entries and evicts them by least-recent use. Serialized
-- visual and event caches remain independent; outdoor physical cells are owned
-- by the field session, while indoor maps retain their aggregate runtime view.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldRegion = require("libs.engine.src.FieldRegion")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local FieldCoverage = require("libs.engine.src.FieldCoverage")
local FieldCellCache = require("libs.assets.src.FieldCellCache")

---@class FieldMapLoader
---@field cacheFs CacheFs
---@field world table
---@field capacity integer
---@field sceneLoader table|nil presentation-only visual scene loader
---@field neighborLoader table|nil presentation-only finite neighbor-ring loader
---@field sceneOptions table|nil options passed to physical-cell presentation loading
---@field fieldCellIndex table?
---@field entries table<integer, table>
---@field protectedMaps table<integer, boolean>
---@field clock integer
---@field released boolean
local FieldMapLoader = {}
FieldMapLoader.__index = FieldMapLoader

---@class RuntimeFieldMap
---@field mapId integer
---@field mapSymbol string
---@field mapSection string
---@field sceneRuntime table|nil
---@field scene table
---@field fieldData table
---@field collision table?
---@field terrain TerrainSurface?
---@field terrainDependencyHash string?
---@field fieldRegion table?
---@field cameraType integer
---@field coordinateOrigin { x: integer, z: integer }
---@field physicalOrigin { x: number, y: number, z: number }?
---@field neighborRuntime table?
---@field coverage FieldCoverage? only on a session-owned composed field view
---@field probePhysicalCell fun(self: RuntimeFieldMap, fieldX: integer, fieldZ: integer, context: PhysicalProbeContext?): table?|nil
---@field release fun(self: RuntimeFieldMap)
---@field updateAnimated fun(self: RuntimeFieldMap)

---@param world table
---@param idOrSymbol string|integer
---@return table
local function worldRecord(world, idOrSymbol)
  local mapId = type(idOrSymbol) == "string" and world.bySymbol[idOrSymbol] or idOrSymbol
  local index = mapId ~= nil and world.byId[mapId] or nil
  local record = index and world.maps[index] or nil
  if not record then
    Errors.raise(FieldErrors.FIELD_MAP_UNKNOWN, "no runtime map for " .. tostring(idOrSymbol), { key = idOrSymbol })
  end
  return assert(record)
end

---@param cacheFs CacheFs
---@param path string
---@param code string
---@return table
local function loadRequired(cacheFs, path, code)
  local value, err = cacheFs:loadLua(path)
  if value == nil then
    Errors.raise(code, "required field cache file is unavailable", {
      path = path,
      cause = err and Errors.format(err),
    })
  end
  return value --[[@as table]]
end

---@param cacheFs CacheFs
---@return table
local function loadFieldCellIndex(cacheFs)
  local path = FieldCellCache.indexPath()
  local index, err = cacheFs:loadLua(path)
  if index == nil then
    Errors.raise(FieldErrors.FIELD_CELL_CACHE_MISSING, "field cell index is unavailable; rebuild the derived cache", {
      path = path,
      cause = err and Errors.format(err),
    })
  end
  local loadedIndex = index --[[@as table]]
  if not FieldCellCache.validateIndex(loadedIndex) then
    Errors.raise(FieldErrors.FIELD_CELL_CACHE_INVALID, "field cell index is malformed; rebuild the derived cache", {
      path = path,
    })
  end
  return loadedIndex
end

local function releaseAggregate(runtimeMap)
  if runtimeMap.released then
    return
  end
  runtimeMap.released = true
  if runtimeMap.neighborRuntime then
    runtimeMap.neighborRuntime:release()
  end
  if runtimeMap.sceneRuntime then
    runtimeMap.sceneRuntime:release()
  end
end

-- The terrain artifact's source record is part of the map dependency identity
-- (see terrainDependencyHash); a missing source or bdhcSha1 is malformed
-- generated data and must fail the load rather than degrade the identity.
local function requireTerrainSource(artifact, context)
  if type(artifact.source) ~= "table" or type(artifact.source.bdhcSha1) ~= "string" then
    Errors.raise(FieldErrors.FIELD_MAP_TERRAIN_CACHE_INVALID, "terrain artifact source or bdhcSha1 is missing", context)
  end
end

-- Decode a collision asset into a runtime grid at a cell origin. Malformed
-- or missing generated collision data fails the load loudly -- a map with a
-- half-decoded grid must never move the player. `missingCode` names the
-- structured failure for the caller's artifact class.
local function loadCollision(cacheFs, descriptor, missingCode, context)
  local file = descriptor.file --[[@as string]]
  local bytes = cacheFs:read(file)
  if type(bytes) ~= "string" then
    Errors.raise(missingCode, "collision asset is unavailable", { path = file, mapId = context.mapId })
  end
  local data = bytes --[[@as string]]
  local grid, decodeErr = CollisionGridAsset.decode(data, { mapId = context.mapId, path = file })
  if not grid then
    error(decodeErr)
  end
  return CollisionGrid.new(grid, {
    worldOriginX = context.worldOriginX or 0,
    worldOriginZ = context.worldOriginZ or 0,
  })
end

local function loadNeighborRegion(cacheFs, scene, centralCollision, centralTerrain)
  local neighbors = {}
  for _, descriptor in ipairs(scene.neighbors) do
    if not descriptor.collision or not descriptor.terrain then
      Errors.raise(
        FieldErrors.FIELD_MAP_NEIGHBOR_CACHE_MISSING,
        "neighbor collision or terrain is missing; rebuild the derived cache",
        { mapId = scene.mapId, offsetTilesX = descriptor.offsetTilesX, offsetTilesZ = descriptor.offsetTilesZ }
      )
    end
    local terrainArtifact = loadRequired(cacheFs, descriptor.terrain.file, FieldErrors.FIELD_MAP_NEIGHBOR_CACHE_MISSING)
    requireTerrainSource(terrainArtifact, {
      mapId = scene.mapId,
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesY = descriptor.offsetTilesY,
      offsetTilesZ = descriptor.offsetTilesZ,
    })
    neighbors[#neighbors + 1] = {
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesY = descriptor.offsetTilesY,
      offsetTilesZ = descriptor.offsetTilesZ,
      collision = loadCollision(cacheFs, descriptor.collision, FieldErrors.FIELD_MAP_NEIGHBOR_CACHE_MISSING, {
        mapId = scene.mapId,
      }),
      terrain = TerrainSurface.new(terrainArtifact),
    }
  end
  return FieldRegion.new(centralCollision, centralTerrain, neighbors)
end

local function terrainDependencyHash(region)
  local identities = { "g4-composite-terrain-v1" }
  for _, cell in ipairs(region.cells) do
    identities[#identities + 1] = string.format(
      "%d:%.17g:%d:%s",
      cell.offsetTilesX,
      cell.offsetTilesY,
      cell.offsetTilesZ,
      cell.terrain.artifact.source.bdhcSha1
    )
  end
  return table.concat(identities, "|")
end

function FieldMapLoader.new(cacheFs, world, options)
  assert(cacheFs and cacheFs.loadLua, "FieldMapLoader requires a CacheFs-shaped object")
  assert(world and world.maps and world.byId and world.bySymbol, "world manifest required")
  options = options or {}
  local capacity = options.capacity or 4
  assert(capacity >= 1 and capacity == math.floor(capacity), "map capacity must be a positive integer")
  -- The visual scene loader and the finite neighbor ring are presentation
  -- collaborators: a simulation-only runtime leaves both out and still gets
  -- collision and terrain through the shared asset paths.
  return setmetatable({
    cacheFs = cacheFs,
    world = world,
    capacity = capacity,
    sceneLoader = options.sceneLoader,
    neighborLoader = options.neighborLoader,
    sceneOptions = options.sceneOptions,
    fieldCellIndex = nil,
    entries = {},
    protectedMaps = {},
    clock = 0,
    released = false,
  }, FieldMapLoader)
end

function FieldMapLoader:_touch(entry)
  self.clock = self.clock + 1
  entry.lastUsed = self.clock
end

function FieldMapLoader:_evict(skipMapId)
  while self:residentCount() > self.capacity do
    local victim
    for mapId, entry in pairs(self.entries) do
      if mapId ~= skipMapId and not self.protectedMaps[mapId] and (not victim or entry.lastUsed < victim.lastUsed) then
        victim = entry
      end
    end
    if not victim then
      return
    end
    self.entries[victim.runtimeMap.mapId] = nil
    releaseAggregate(victim.runtimeMap)
  end
end

function FieldMapLoader:load(idOrSymbol, _)
  assert(not self.released, "field map loader is released")
  local record = worldRecord(self.world, idOrSymbol)
  local existing = self.entries[record.id]
  if existing then
    self:_touch(existing)
    return existing.runtimeMap
  end

  local mapDir = MapAssetCache.mapDir(record.id)
  local scene = loadRequired(self.cacheFs, mapDir .. "/scene.lua", FieldErrors.FIELD_MAP_VISUAL_CACHE_MISSING)
  local fieldData =
    loadRequired(self.cacheFs, FieldMapDataCache.fieldPath(record.id), FieldErrors.FIELD_MAP_DATA_CACHE_MISSING)
  local terrainArtifact
  if scene.schema ~= MapAssetCache.SCENE_SCHEMA or scene.mapId ~= record.id then
    Errors.raise(
      FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
      "visual cache identity or schema mismatch",
      { mapId = record.id, schema = scene.schema }
    )
  end
  if type(scene.neighbors) ~= "table" then
    Errors.raise(
      FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
      "scene neighbors record is missing or malformed; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  if fieldData.schema ~= FieldMapDataCache.FIELD_SCHEMA or fieldData.mapId ~= record.id then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache identity or schema mismatch",
      { mapId = record.id, schema = fieldData.schema }
    )
  end
  if not FieldMapDataCache.hasRequiredEvents(fieldData.events) then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache event collections are missing or malformed; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  if not FieldMapDataCache.isTransitionEnvironment(fieldData.transitionEnvironment) then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache transition environment is missing or malformed; rebuild the derived cache",
      { mapId = record.id, transitionEnvironment = fieldData.transitionEnvironment }
    )
  end
  if fieldData.cameraType ~= scene.cameraType then
    Errors.raise(
      FieldErrors.FIELD_MAP_CAMERA_MISMATCH,
      "visual and field camera types disagree",
      { mapId = record.id, visualCameraType = scene.cameraType, fieldCameraType = fieldData.cameraType }
    )
  end

  local physicalCells = scene.type == "outdoor"
  if physicalCells and not self.fieldCellIndex then
    self.fieldCellIndex = loadFieldCellIndex(self.cacheFs)
  end
  if not physicalCells then
    terrainArtifact =
      loadRequired(self.cacheFs, MapAssetCache.terrainPath(record.id), FieldErrors.FIELD_MAP_TERRAIN_CACHE_MISSING)
    if terrainArtifact.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      Errors.raise(
        FieldErrors.FIELD_MAP_TERRAIN_CACHE_INVALID,
        "terrain cache schema mismatch",
        { mapId = record.id, schema = terrainArtifact.schema }
      )
    end
    requireTerrainSource(terrainArtifact, { mapId = record.id })
  end
  -- Outdoor cells own collision, terrain, and geometry. The logical scene
  -- contributes only environment state; indoor maps retain their aggregate.
  local sceneRuntime
  if self.sceneLoader then
    sceneRuntime = physicalCells and self.sceneLoader.loadEnvironment(scene)
      or self.sceneLoader.load(self.cacheFs, scene)
  end
  -- One transaction covers every step after the scene runtime is acquired:
  -- neighbor-ring load, collision decode, terrain construction, neighbor decoding,
  -- region assembly, and aggregate construction. Any failure releases the
  -- neighbor runtime (if created) and the scene runtime exactly once before
  -- the error propagates; a failure inside the scene loader itself is that
  -- loader's own transaction.
  local neighborRuntime
  local runtimeMap
  local ok, loadErr = pcall(function()
    if not physicalCells and self.neighborLoader and #scene.neighbors > 0 then
      neighborRuntime = self.neighborLoader.load(self.cacheFs, scene.neighbors, {
        textureSrt = scene.terrainAnimations.textureSrt,
      })
    end

    if not physicalCells and (not scene.collision or type(scene.collision.file) ~= "string") then
      Errors.raise(
        FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
        "scene collision descriptor is missing; rebuild the derived cache",
        { mapId = record.id }
      )
    end
    local region
    if not physicalCells then
      local centralCollision =
        loadCollision(self.cacheFs, scene.collision, FieldErrors.FIELD_MAP_COLLISION_CACHE_MISSING, {
          mapId = record.id,
          worldOriginX = scene.matrix.worldOriginX,
          worldOriginZ = scene.matrix.worldOriginZ,
        })
      local centralTerrain = TerrainSurface.new(assert(terrainArtifact))
      region = loadNeighborRegion(self.cacheFs, scene, centralCollision, centralTerrain)
    end
    runtimeMap = {
      mapId = record.id,
      mapSymbol = record.symbol,
      mapSection = record.mapSection,
      sceneRuntime = sceneRuntime,
      scene = scene,
      fieldData = fieldData,
      collision = region and region.collision or nil,
      terrain = region and region.terrain or nil,
      terrainDependencyHash = region and terrainDependencyHash(region) or nil,
      fieldRegion = region,
      cameraType = scene.cameraType,
      coordinateOrigin = { x = scene.matrix.worldOriginX, z = scene.matrix.worldOriginZ },
      physicalOrigin = nil,
      neighborRuntime = neighborRuntime,
      released = false,
    }
    function runtimeMap:probePhysicalCell(_, _)
      return nil
    end
    function runtimeMap:release()
      releaseAggregate(self)
    end
    -- The one fixed-tick entry FieldSession steps the physical window when
    -- field cells are active; logical scene animation is used otherwise.
    function runtimeMap:updateAnimated()
      if self.sceneRuntime and self.sceneRuntime.updateAnimated then
        self.sceneRuntime:updateAnimated()
      end
      if self.neighborRuntime then
        self.neighborRuntime:updateAnimated()
      end
    end

    local entry = { runtimeMap = runtimeMap }
    self.entries[record.id] = entry
    self:_touch(entry)
  end)
  if not ok then
    if neighborRuntime then
      neighborRuntime:release()
    end
    if sceneRuntime then
      sceneRuntime:release()
    end
    error(loadErr)
  end

  self:_evict(record.id)
  return runtimeMap
end

-- Construct the session-owned physical window for an outdoor logical map.
-- The loader provides validated cache access and presentation construction,
-- but never stores or releases the returned owner.
---@param runtimeMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@return FieldCoverage
function FieldMapLoader:createPhysicalCoverage(runtimeMap, position)
  assert(not self.released, "field map loader is released")
  assert(runtimeMap and runtimeMap.scene and runtimeMap.scene.type == "outdoor", "outdoor logical map required")
  local fieldCellIndex = assert(self.fieldCellIndex, "field cell cache is unavailable")
  assert(type(position) == "table", "physical coverage position required")
  local record = worldRecord(self.world, runtimeMap.mapId)
  local matrix = assert(record.matrix, "outdoor map matrix metadata is required")
  local matrixMemberId = assert(matrix.memberId, "outdoor matrix member is required")
  local presentationLoader
  if self.sceneLoader and self.sceneLoader.loadCell then
    presentationLoader = function(_, cell)
      return self.sceneLoader.loadCell(self.cacheFs, cell, self.sceneOptions)
    end
  end
  return FieldCoverage.new({
    cacheFs = self.cacheFs,
    index = fieldCellIndex,
    matrixMemberId = matrixMemberId,
    anchorX = math.floor(position.fieldX / 32),
    anchorZ = math.floor(position.fieldZ / 32),
    presentationLoader = presentationLoader,
  })
end

-- Read only the generated semantic metadata needed to choose a transition.
-- This deliberately does not load a scene, collision grid, terrain, or GPU
-- resource, so profile selection cannot acquire destination ownership.
function FieldMapLoader:transitionEnvironment(idOrSymbol)
  assert(not self.released, "field map loader is released")
  local record = worldRecord(self.world, idOrSymbol)
  local fieldData =
    loadRequired(self.cacheFs, FieldMapDataCache.fieldPath(record.id), FieldErrors.FIELD_MAP_DATA_CACHE_MISSING)
  if
    fieldData.schema ~= FieldMapDataCache.FIELD_SCHEMA
    or fieldData.mapId ~= record.id
    or not FieldMapDataCache.hasRequiredEvents(fieldData.events)
    or not FieldMapDataCache.isTransitionEnvironment(fieldData.transitionEnvironment)
  then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache identity, event collections, or transition environment is invalid; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  return fieldData.transitionEnvironment
end

function FieldMapLoader:get(mapId)
  local entry = self.entries[mapId]
  return entry and entry.runtimeMap or nil
end

-- Counts currently resident map entries without acquiring or releasing them.
function FieldMapLoader:residentCount()
  local count = 0
  for _ in pairs(self.entries) do
    count = count + 1
  end
  return count
end

function FieldMapLoader:protectMap(mapId, protected)
  assert(type(mapId) == "number", "mapId required")
  self.protectedMaps[mapId] = protected and true or nil
  if not protected then
    self:_evict()
  end
end

function FieldMapLoader:release()
  if self.released then
    return
  end
  self.released = true
  for _, entry in pairs(self.entries) do
    releaseAggregate(entry.runtimeMap)
  end
  self.entries, self.protectedMaps = {}, {}
end

return FieldMapLoader
