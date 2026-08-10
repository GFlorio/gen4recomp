-- Readiness and invalidation for the derived map-asset cache. This cache has its
-- own format version, fully independent of the raw ROM dump: changing it may
-- rebuild derived maps but must never disturb rom-dump.complete, romfs/, or the
-- raw dump indexes. A map is ready only when its completion marker matches
-- exactly and every artifact it references is present and loadable, so a
-- partial or stale build never reads as complete. Paths are cache-relative; all
-- IO goes through a CacheFs (which confines every write to the version subtree).

local MapAssetCache = {}

local Errors = require("libs.rom.src.Errors")
local Validate = require("libs.assets.src.Validate")

MapAssetCache.FORMAT = "map-cache-v5"
MapAssetCache.SCENE_SCHEMA = "g4-map-scene-v3"

local DERIVED_DATA = "data/generated"
local DERIVED_ASSETS = "assets/generated"

function MapAssetCache.mapDir(mapId)
  return string.format("%s/maps/%04d", DERIVED_DATA, mapId)
end

function MapAssetCache.terrainPath(mapId)
  return MapAssetCache.mapDir(mapId) .. "/terrain.lua"
end

function MapAssetCache.neighborPermissionsPath(mapId, landDataMemberId)
  return string.format("%s/neighbors/%d/permissions.bin", MapAssetCache.mapDir(mapId), landDataMemberId)
end

function MapAssetCache.neighborTerrainPath(mapId, landDataMemberId)
  return string.format("%s/neighbors/%d/terrain.lua", MapAssetCache.mapDir(mapId), landDataMemberId)
end

-- Cache-relative path to the whole-ROM world manifest (map index the game boots
-- and switches on). Lives next to the per-map dirs, under the derived root.
function MapAssetCache.worldPath()
  return DERIVED_DATA .. "/world.lua"
end

function MapAssetCache.geometryPath(sha1)
  return string.format("%s/maps/geometry/%s.g4mesh", DERIVED_ASSETS, sha1)
end

function MapAssetCache.texturePath(sha1)
  return string.format("%s/maps/textures/%s.png", DERIVED_ASSETS, sha1)
end

function MapAssetCache.modelPath(modelKey)
  -- Model keys embed ':' (archive:member:hash); keep them filesystem-safe.
  return string.format("%s/models/%s.lua", DERIVED_DATA, (modelKey:gsub(":", "_")))
end

function MapAssetCache.marker(romSha1, mapId, depHash)
  return string.format("%s:%s:%d:%s", MapAssetCache.FORMAT, romSha1, mapId, depHash)
end

-- Collect every cache-relative path the scene references, recursing into model
-- descriptors so a stale or missing model geometry/texture is caught. The
-- scene shape is validated strictly: the current compiler always writes these
-- fields, so malformed structure raises MAP_CACHE_SCENE_INVALID instead of
-- being defaulted to empty collections.
function MapAssetCache.referencedPaths(scene, cacheFs)
  local paths = {}

  local function invalid(reason)
    Errors.raise("MAP_CACHE_SCENE_INVALID", "scene descriptor is malformed: " .. reason, { reason = reason })
  end

  if not Validate.isArray(scene.mapBatches) then
    invalid("mapBatches is not an array")
  end
  if not Validate.isArray(scene.materials) then
    invalid("materials is not an array")
  end
  if not Validate.isArray(scene.buildingInstances) then
    invalid("buildingInstances is not an array")
  end
  if not Validate.isArray(scene.neighbors) then
    invalid("neighbors is not an array")
  end

  if scene.terrain and type(scene.terrain) == "table" and scene.terrain.file then
    paths[#paths + 1] = scene.terrain.file
  end

  local function addBatch(b)
    if type(b) ~= "table" or type(b.geometry) ~= "string" then
      invalid("a batch does not reference a geometry path")
    end
    paths[#paths + 1] = b.geometry
  end
  local function addMaterial(m)
    if type(m) ~= "table" or (m.texture ~= nil and type(m.texture) ~= "string") then
      invalid("a material is not a record with an optional texture path")
    end
    if m.texture then
      paths[#paths + 1] = m.texture
    end
  end

  for _, b in ipairs(scene.mapBatches) do
    addBatch(b)
  end
  for _, m in ipairs(scene.materials) do
    addMaterial(m)
  end
  for _, cell in ipairs(scene.neighbors) do
    if type(cell) ~= "table" or not Validate.isArray(cell.batches) or not Validate.isArray(cell.materials) then
      invalid("a neighbor cell does not carry batches and materials arrays")
    end
    for _, b in ipairs(cell.batches) do
      addBatch(b)
    end
    for _, m in ipairs(cell.materials) do
      addMaterial(m)
    end
    if type(cell.collision) == "table" and cell.collision.file then
      paths[#paths + 1] = cell.collision.file
    end
    if type(cell.terrain) == "table" and cell.terrain.file then
      paths[#paths + 1] = cell.terrain.file
    end
  end
  for _, inst in ipairs(scene.buildingInstances) do
    if type(inst) ~= "table" or type(inst.modelKey) ~= "string" then
      invalid("a building instance does not carry a modelKey")
    end
    local modelPath = MapAssetCache.modelPath(inst.modelKey)
    paths[#paths + 1] = modelPath
    local desc = cacheFs and cacheFs:loadLua(modelPath)
    if type(desc) ~= "table" then
      invalid("model descriptor does not load: " .. inst.modelKey)
    end
    if not Validate.isArray(desc.batches) or not Validate.isArray(desc.materials) then
      invalid("model descriptor batches/materials are not arrays: " .. inst.modelKey)
    end
    for _, b in ipairs(desc.batches) do
      addBatch(b)
    end
    for _, m in ipairs(desc.materials) do
      addMaterial(m)
    end
  end
  return paths
end

-- True only if the marker is exact, the scene carries the current identity
-- (schema and mapId), scene/dependencies/terrain load, permissions.bin is
-- exactly 2048 bytes, every model descriptor opens, and every referenced asset
-- exists. A malformed scene shape reports not ready rather than raising.
function MapAssetCache.isReady(cacheFs, mapId, expectedMarker)
  local dir = MapAssetCache.mapDir(mapId)
  local marker = cacheFs:read(dir .. "/complete")
  if marker ~= expectedMarker then
    return false
  end

  local scene = cacheFs:loadLua(dir .. "/scene.lua")
  if type(scene) ~= "table" then
    return false
  end
  if scene.schema ~= MapAssetCache.SCENE_SCHEMA or scene.mapId ~= mapId then
    return false
  end
  if not cacheFs:loadLua(dir .. "/dependencies.lua") then
    return false
  end
  local terrain = cacheFs:loadLua(MapAssetCache.terrainPath(mapId))
  if type(terrain) ~= "table" or terrain.schema ~= "g4-terrain-surfaces-v1" then
    return false
  end

  local perms = cacheFs:getInfo(dir .. "/permissions.bin")
  if not perms or perms.type ~= "file" or perms.size ~= 2048 then
    return false
  end

  local ok, paths = pcall(MapAssetCache.referencedPaths, scene, cacheFs)
  if not ok then
    if Errors.is(paths) and paths.code == "MAP_CACHE_SCENE_INVALID" then
      return false
    end
    error(paths)
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path) then
      return false
    end
  end
  for _, cell in ipairs(scene.neighbors) do
    if type(cell.collision) == "table" and cell.collision.file then
      local info = cacheFs:getInfo(cell.collision.file)
      if not info or info.type ~= "file" or info.size ~= 2048 then
        return false
      end
    end
    if type(cell.terrain) == "table" and cell.terrain.file then
      local neighborTerrain = cacheFs:loadLua(cell.terrain.file)
      if type(neighborTerrain) ~= "table" or neighborTerrain.schema ~= "g4-terrain-surfaces-v1" then
        return false
      end
    end
  end
  return true
end

function MapAssetCache.dependencies(cacheFs, mapId)
  return cacheFs:loadLua(MapAssetCache.mapDir(mapId) .. "/dependencies.lua")
end

function MapAssetCache.invalidateMap(cacheFs, mapId)
  cacheFs:removeTree(MapAssetCache.mapDir(mapId))
  return true
end

-- Remove all derived subtrees, never the raw dump. Asserts it targets only the
-- generated roots so a refactor can't point it at rom-dump.complete or romfs/.
function MapAssetCache.invalidateAllDerived(cacheFs)
  local derivedPaths = {
    DERIVED_DATA .. "/maps",
    DERIVED_DATA .. "/models",
    MapAssetCache.worldPath(),
    DERIVED_ASSETS,
  }
  for _, root in ipairs(derivedPaths) do
    assert(root:find("generated", 1, true), "derived root must live under a generated subtree")
    cacheFs:removeTree(root)
  end
  return true
end

return MapAssetCache
