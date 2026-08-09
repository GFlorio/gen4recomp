-- Readiness and invalidation for the derived map-asset cache. This cache has its
-- own format version, fully independent of the raw ROM dump: changing it may
-- rebuild derived maps but must never disturb rom-dump.complete, romfs/, or the
-- raw dump indexes. A map is ready only when its completion marker matches
-- exactly and every artifact it references is present and loadable, so a
-- partial or stale build never reads as complete. Paths are cache-relative; all
-- IO goes through a CacheFs (which confines every write to the version subtree).

local MapAssetCache = {}

MapAssetCache.FORMAT = "map-cache-v5"

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
-- descriptors so a stale or missing model geometry/texture is caught.
function MapAssetCache.referencedPaths(scene, cacheFs)
  local paths = {}

  if scene.terrain and scene.terrain.file then
    paths[#paths + 1] = scene.terrain.file
  end

  local function addBatch(b)
    if b.geometry then
      paths[#paths + 1] = b.geometry
    end
  end
  local function addMaterial(m)
    if m.texture then
      paths[#paths + 1] = m.texture
    end
  end

  for _, b in ipairs(scene.mapBatches or {}) do
    addBatch(b)
  end
  for _, m in ipairs(scene.materials or {}) do
    addMaterial(m)
  end
  for _, cell in ipairs(scene.neighbors or {}) do
    for _, b in ipairs(cell.batches or {}) do
      addBatch(b)
    end
    for _, m in ipairs(cell.materials or {}) do
      addMaterial(m)
    end
    if cell.collision and cell.collision.file then
      paths[#paths + 1] = cell.collision.file
    end
    if cell.terrain and cell.terrain.file then
      paths[#paths + 1] = cell.terrain.file
    end
  end
  for _, inst in ipairs(scene.buildingInstances or {}) do
    if inst.modelKey then
      local modelPath = MapAssetCache.modelPath(inst.modelKey)
      paths[#paths + 1] = modelPath
      local desc = cacheFs and cacheFs:loadLua(modelPath)
      if type(desc) == "table" then
        for _, b in ipairs(desc.batches or {}) do
          addBatch(b)
        end
        for _, m in ipairs(desc.materials or {}) do
          addMaterial(m)
        end
      end
    end
  end
  return paths
end

-- True only if the marker is exact, scene/dependencies/terrain load,
-- permissions.bin is exactly 2048 bytes, every model descriptor opens, and
-- every referenced asset exists.
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

  for _, path in ipairs(MapAssetCache.referencedPaths(scene, cacheFs)) do
    if not cacheFs:exists(path) then
      return false
    end
  end
  for _, cell in ipairs(scene.neighbors or {}) do
    if cell.collision and cell.collision.file then
      local info = cacheFs:getInfo(cell.collision.file)
      if not info or info.type ~= "file" or info.size ~= 2048 then
        return false
      end
    end
    if cell.terrain and cell.terrain.file then
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
