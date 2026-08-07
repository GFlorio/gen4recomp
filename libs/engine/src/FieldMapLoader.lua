-- Owns live field-map aggregates and evicts them by least-recent use. Serialized
-- visual, event, permission, and terrain caches remain independent; this loader
-- only joins their validated runtime views and releases owned GPU resources.

local Errors = require("libs.rom.src.Errors")
local FieldCoveragePlanner = require("libs.engine.src.FieldCoveragePlanner")
local FieldGrid = require("libs.engine.src.FieldGrid")
local FieldRegion = require("libs.engine.src.FieldRegion")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local PermissionGrid = require("libs.assets.src.PermissionGrid")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local NeighborRing = require("libs.engine.src.NeighborRing")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

---@class FieldMapLoader
---@field cacheFs CacheFs
---@field world table
---@field capacity integer
---@field sceneLoader table
---@field coverageLoader table
---@field entries table<integer, table>
---@field protectedMaps table<integer, boolean>
---@field protectedCells table<integer, table>
---@field clock integer
---@field released boolean
local FieldMapLoader = {}
FieldMapLoader.__index = FieldMapLoader


---@class RuntimeFieldMap
---@field mapId integer
---@field mapSymbol string
---@field sceneRuntime table
---@field scene table
---@field fieldData table
---@field permissions table
---@field terrain TerrainSurface
---@field terrainDependencyHash string
---@field fieldRegion table
---@field cameraType integer
---@field coordinateOrigin { x: integer, z: integer }
---@field coverageRuntime table?
---@field coveragePlan table?
---@field availableCells table<string, boolean>
---@field release fun(self: RuntimeFieldMap)

---@param world table
---@param idOrSymbol string|integer
---@return table
local function worldRecord(world, idOrSymbol)
  local mapId = type(idOrSymbol) == "string" and world.bySymbol[idOrSymbol] or idOrSymbol
  local index = mapId ~= nil and world.byId[mapId] or nil
  local record = index and world.maps[index] or nil
  if not record then
    Errors.raise("FIELD_MAP_UNKNOWN", "no runtime map for " .. tostring(idOrSymbol),
      { key = idOrSymbol })
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
      path = path, cause = err and err.code,
    })
  end
  return value --[[@as table]]
end

local function availableCells(scene)
  local available = {}
  local function add(x, z) available[x .. ":" .. z] = true end
  add(scene.matrix.x, scene.matrix.z)
  for _, descriptor in ipairs(scene.neighbors or {}) do
    assert(descriptor.offsetTilesX % FieldGrid.CELL_TILES == 0
      and descriptor.offsetTilesZ % FieldGrid.CELL_TILES == 0,
      "neighbor offsets must align to field cells")
    add(scene.matrix.x + descriptor.offsetTilesX / FieldGrid.CELL_TILES,
      scene.matrix.z + descriptor.offsetTilesZ / FieldGrid.CELL_TILES)
  end
  return available
end

local function releaseAggregate(runtimeMap)
  if runtimeMap.released then return end
  runtimeMap.released = true
  if runtimeMap.coverageRuntime then runtimeMap.coverageRuntime:release() end
  runtimeMap.sceneRuntime:release()
end

local function loadNeighborRegion(cacheFs, scene, centralCollision, centralTerrain)
  local neighbors = {}
  for _, descriptor in ipairs(scene.neighbors or {}) do
    if not descriptor.collision or not descriptor.terrain then
      Errors.raise("FIELD_MAP_NEIGHBOR_CACHE_MISSING",
        "neighbor collision or terrain is missing; rebuild the derived cache",
        { mapId = scene.mapId, offsetTilesX = descriptor.offsetTilesX,
          offsetTilesZ = descriptor.offsetTilesZ })
    end
    local permissionBytes = cacheFs:read(descriptor.collision.file)
    if not permissionBytes then
      Errors.raise("FIELD_MAP_NEIGHBOR_CACHE_MISSING", "neighbor permissions are unavailable",
        { mapId = scene.mapId, path = descriptor.collision.file })
    end
    local permissionGrid, permissionErr = PermissionGrid.decode(permissionBytes, {
      mapId = scene.mapId, path = descriptor.collision.file,
    })
    if not permissionGrid then error(permissionErr) end
    local terrainArtifact = loadRequired(cacheFs, descriptor.terrain.file,
      "FIELD_MAP_NEIGHBOR_CACHE_MISSING")
    neighbors[#neighbors + 1] = {
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesZ = descriptor.offsetTilesZ,
      collision = CollisionGrid.new(permissionGrid),
      terrain = TerrainSurface.new(terrainArtifact),
    }
  end
  return FieldRegion.new(centralCollision, centralTerrain, neighbors)
end

local function terrainDependencyHash(region)
  local identities = { "g4-composite-terrain-v1" }
  for _, cell in ipairs(region.cells) do
    local source = cell.terrain.artifact.source or {}
    identities[#identities + 1] = string.format("%d:%d:%s",
      cell.offsetTilesX, cell.offsetTilesZ, tostring(source.bdhcSha1 or "unknown"))
  end
  return table.concat(identities, "|")
end

function FieldMapLoader.new(cacheFs, world, options)
  assert(cacheFs and cacheFs.loadLua, "FieldMapLoader requires a CacheFs-shaped object")
  assert(world and world.maps and world.byId and world.bySymbol, "world manifest required")
  options = options or {}
  local capacity = options.capacity or 4
  assert(capacity >= 1 and capacity == math.floor(capacity), "map capacity must be a positive integer")
  return setmetatable({
    cacheFs = cacheFs,
    world = world,
    capacity = capacity,
    sceneLoader = options.sceneLoader or MapSceneLoader,
    coverageLoader = options.coverageLoader or NeighborRing,
    entries = {},
    protectedMaps = {},
    protectedCells = {},
    clock = 0,
    released = false,
  }, FieldMapLoader)
end

function FieldMapLoader:_touch(entry)
  self.clock = self.clock + 1
  entry.lastUsed = self.clock
end

function FieldMapLoader:_isProtected(mapId)
  return self.protectedMaps[mapId] or next(self.protectedCells[mapId] or {}) ~= nil
end

function FieldMapLoader:_evict(skipMapId)
  while self:residentCount() > self.capacity do
    local victim
    for mapId, entry in pairs(self.entries) do
      if mapId ~= skipMapId and not self:_isProtected(mapId)
        and (not victim or entry.lastUsed < victim.lastUsed) then
        victim = entry
      end
    end
    if not victim then return end
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
  local scene = loadRequired(self.cacheFs, mapDir .. "/scene.lua", "FIELD_MAP_VISUAL_CACHE_MISSING")
  local fieldData = loadRequired(self.cacheFs, FieldMapDataCache.fieldPath(record.id),
    "FIELD_MAP_DATA_CACHE_MISSING")
  local terrainArtifact = loadRequired(self.cacheFs, MapAssetCache.terrainPath(record.id),
    "FIELD_MAP_TERRAIN_CACHE_MISSING")
  if scene.schema ~= "g4-map-scene-v3" or scene.mapId ~= record.id then
    Errors.raise("FIELD_MAP_VISUAL_CACHE_INVALID", "visual cache identity or schema mismatch",
      { mapId = record.id, schema = scene.schema })
  end
  if fieldData.schema ~= "g4-field-map-v1" or fieldData.mapId ~= record.id then
    Errors.raise("FIELD_MAP_DATA_CACHE_INVALID", "field cache identity or schema mismatch",
      { mapId = record.id, schema = fieldData.schema })
  end
  if terrainArtifact.schema ~= "g4-terrain-surfaces-v1" then
    Errors.raise("FIELD_MAP_TERRAIN_CACHE_INVALID", "terrain cache schema mismatch",
      { mapId = record.id, schema = terrainArtifact.schema })
  end
  if fieldData.cameraType ~= scene.cameraType then
    Errors.raise("FIELD_MAP_CAMERA_MISMATCH", "visual and field camera types disagree",
      { mapId = record.id, visualCameraType = scene.cameraType,
        fieldCameraType = fieldData.cameraType })
  end

  local sceneRuntime = self.sceneLoader.load(self.cacheFs, scene)
  local coverageRuntime
  local ok, loadErr = pcall(function()
    if #(scene.neighbors or {}) > 0 then
      coverageRuntime = self.coverageLoader.load(self.cacheFs, scene.neighbors)
    end
  end)
  if not ok then
    sceneRuntime:release()
    error(loadErr)
  end

  local centralTerrain = TerrainSurface.new(terrainArtifact)
  local region = loadNeighborRegion(self.cacheFs, scene, sceneRuntime.collision, centralTerrain)
  local runtimeMap = {
    mapId = record.id,
    mapSymbol = record.symbol,
    sceneRuntime = sceneRuntime,
    scene = scene,
    fieldData = fieldData,
    permissions = region.permissions,
    terrain = region.terrain,
    terrainDependencyHash = terrainDependencyHash(region),
    fieldRegion = region,
    cameraType = scene.cameraType,
    coordinateOrigin = { x = scene.matrix.worldOriginX, z = scene.matrix.worldOriginZ },
    coverageRuntime = coverageRuntime,
    availableCells = availableCells(scene),
    released = false,
  }
  function runtimeMap:release() releaseAggregate(self) end

  local entry = { runtimeMap = runtimeMap }
  self.entries[record.id] = entry
  self:_touch(entry)
  self:_evict(record.id)
  return runtimeMap
end

function FieldMapLoader:get(mapId)
  local entry = self.entries[mapId]
  return entry and entry.runtimeMap or nil
end

function FieldMapLoader:residentCount()
  local count = 0
  for _ in pairs(self.entries) do count = count + 1 end
  return count
end

function FieldMapLoader:protectMap(mapId, protected)
  assert(type(mapId) == "number", "mapId required")
  self.protectedMaps[mapId] = protected and true or nil
  if not protected then self:_evict() end
end

function FieldMapLoader:protectCells(mapId, cells)
  local keys = {}
  for _, cell in ipairs(cells or {}) do keys[cell.x .. ":" .. cell.z] = true end
  self.protectedCells[mapId] = keys
  if next(keys) == nil then self:_evict() end
end

function FieldMapLoader:updateCoverage(runtimeMap, camera, envelope, options)
  assert(self.entries[runtimeMap.mapId]
    and self.entries[runtimeMap.mapId].runtimeMap == runtimeMap, "runtime map is not resident")
  local matrix = runtimeMap.scene.matrix
  options = options or {}
  local planOptions = {
    matrixWidth = matrix.width,
    matrixHeight = matrix.height,
    cellSize = FieldGrid.CELL_TILES,
    -- Render coordinates are centred on the active cell, not global field X/Z.
    worldOriginX = -FieldGrid.CELL_TILES / 2 - matrix.x * FieldGrid.CELL_TILES,
    worldOriginZ = -FieldGrid.CELL_TILES / 2 - matrix.z * FieldGrid.CELL_TILES,
  }
  local bounds = FieldCoveragePlanner.frustumGroundBounds(camera, envelope)
  planOptions.prefetchMargin = 0
  local visiblePlan = FieldCoveragePlanner.planBounds(bounds, planOptions)
  local missingVisible, visibleKeys = {}, {}
  for _, cell in ipairs(visiblePlan.cells) do
    visibleKeys[cell.x .. ":" .. cell.z] = true
    if not runtimeMap.availableCells[cell.x .. ":" .. cell.z] then
      missingVisible[#missingVisible + 1] = cell
    end
  end

  -- The compiled neighbour ring is finite. Visible cells are mandatory, while
  -- the one-cell lookahead is best-effort at that boundary.
  planOptions.prefetchMargin = options.prefetchMargin or 1
  local plan = FieldCoveragePlanner.planBounds(bounds, planOptions)
  local loaded, missing = {}, {}
  for _, cell in ipairs(plan.cells) do
    if runtimeMap.availableCells[cell.x .. ":" .. cell.z] then
      loaded[#loaded + 1] = cell
    elseif not visibleKeys[cell.x .. ":" .. cell.z] then
      missing[#missing + 1] = cell
    end
  end
  plan.cells = loaded
  plan.missingVisibleCells = missingVisible
  plan.missingPrefetchCells = missing
  self:protectCells(runtimeMap.mapId, plan.cells)
  runtimeMap.coveragePlan = plan
  return plan
end

function FieldMapLoader:release()
  if self.released then return end
  self.released = true
  for _, entry in pairs(self.entries) do releaseAggregate(entry.runtimeMap) end
  self.entries, self.protectedMaps, self.protectedCells = {}, {}, {}
end

return FieldMapLoader
