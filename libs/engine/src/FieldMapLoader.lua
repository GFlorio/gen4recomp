-- Owns live field-map aggregates and evicts them by least-recent use. Serialized
-- visual, event, collision, and terrain caches remain independent; this loader
-- joins their validated runtime views. The central and neighbor collision
-- grids decode through the same pure project-owned asset path regardless of
-- presentation: the visual scene loader (MapSceneLoader) and the neighbor
-- ring are optional presentation-only collaborators supplied by the
-- composition, and a simulation-only runtime simply leaves them out.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldRegion = require("libs.engine.src.FieldRegion")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

---@class FieldMapLoader
---@field cacheFs CacheFs
---@field world table
---@field capacity integer
---@field sceneLoader table|nil presentation-only visual scene loader
---@field neighborLoader table|nil presentation-only finite neighbor-ring loader
---@field entries table<integer, table>
---@field protectedMaps table<integer, boolean>
---@field clock integer
---@field released boolean
local FieldMapLoader = {}
FieldMapLoader.__index = FieldMapLoader

---@class RuntimeFieldMap
---@field mapId integer
---@field mapSymbol string
---@field sceneRuntime table|nil
---@field scene table
---@field fieldData table
---@field collision table
---@field terrain TerrainSurface
---@field terrainDependencyHash string
---@field fieldRegion table
---@field cameraType integer
---@field coordinateOrigin { x: integer, z: integer }
---@field neighborRuntime table?
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
      cause = err and err.code,
    })
  end
  return value --[[@as table]]
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
  local bytes = cacheFs:read(descriptor.file)
  if type(bytes) ~= "string" then
    Errors.raise(missingCode, "collision asset is unavailable", { path = descriptor.file, mapId = context.mapId })
  end
  local grid, decodeErr = CollisionGridAsset.decode(bytes, { mapId = context.mapId, path = descriptor.file })
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
      offsetTilesZ = descriptor.offsetTilesZ,
    })
    neighbors[#neighbors + 1] = {
      offsetTilesX = descriptor.offsetTilesX,
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
    identities[#identities + 1] =
      string.format("%d:%d:%s", cell.offsetTilesX, cell.offsetTilesZ, cell.terrain.artifact.source.bdhcSha1)
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

function FieldMapLoader:load(idOrSymbol)
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
  local terrainArtifact =
    loadRequired(self.cacheFs, MapAssetCache.terrainPath(record.id), FieldErrors.FIELD_MAP_TERRAIN_CACHE_MISSING)
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
  if terrainArtifact.schema ~= MapAssetCache.TERRAIN_SCHEMA then
    Errors.raise(
      FieldErrors.FIELD_MAP_TERRAIN_CACHE_INVALID,
      "terrain cache schema mismatch",
      { mapId = record.id, schema = terrainArtifact.schema }
    )
  end
  requireTerrainSource(terrainArtifact, { mapId = record.id })
  if fieldData.cameraType ~= scene.cameraType then
    Errors.raise(
      FieldErrors.FIELD_MAP_CAMERA_MISMATCH,
      "visual and field camera types disagree",
      { mapId = record.id, visualCameraType = scene.cameraType, fieldCameraType = fieldData.cameraType }
    )
  end

  -- The central collision decodes through the same pure project-owned asset
  -- path whether or not presentation is enabled, so simulation and rendering
  -- can never disagree about blocking. The visual scene runtime is optional:
  -- only a presentation composition supplies a scene loader.
  local sceneRuntime
  if self.sceneLoader then
    sceneRuntime = self.sceneLoader.load(self.cacheFs, scene)
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
    if self.neighborLoader and #scene.neighbors > 0 then
      neighborRuntime = self.neighborLoader.load(self.cacheFs, scene.neighbors, {
        textureSrt = scene.terrainAnimations.textureSrt,
      })
    end

    if not scene.collision or type(scene.collision.file) ~= "string" then
      Errors.raise(
        FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
        "scene collision descriptor is missing; rebuild the derived cache",
        { mapId = record.id }
      )
    end
    local centralCollision =
      loadCollision(self.cacheFs, scene.collision, FieldErrors.FIELD_MAP_COLLISION_CACHE_MISSING, {
        mapId = record.id,
        worldOriginX = scene.matrix.worldOriginX,
        worldOriginZ = scene.matrix.worldOriginZ,
      })
    local centralTerrain = TerrainSurface.new(terrainArtifact)
    local region = loadNeighborRegion(self.cacheFs, scene, centralCollision, centralTerrain)
    runtimeMap = {
      mapId = record.id,
      mapSymbol = record.symbol,
      sceneRuntime = sceneRuntime,
      scene = scene,
      fieldData = fieldData,
      collision = region.collision,
      terrain = region.terrain,
      terrainDependencyHash = terrainDependencyHash(region),
      fieldRegion = region,
      cameraType = scene.cameraType,
      coordinateOrigin = { x = scene.matrix.worldOriginX, z = scene.matrix.worldOriginZ },
      neighborRuntime = neighborRuntime,
      released = false,
    }
    function runtimeMap:release()
      releaseAggregate(self)
    end
    -- The one fixed-tick entry FieldSession steps: fans out to the central
    -- scene runtime and the neighbor ring runtime, each guarded so a
    -- simulation-only aggregate (no presentation runtimes) stays a safe no-op.
    function runtimeMap:updateAnimated()
      if self.sceneRuntime then
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

function FieldMapLoader:get(mapId)
  local entry = self.entries[mapId]
  return entry and entry.runtimeMap or nil
end

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
