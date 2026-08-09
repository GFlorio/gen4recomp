-- Persists a compiled map bundle to the derived cache in a marker-last
-- transaction: shared content-addressed meshes and textures first, then model
-- descriptors, the permission grid, terrain surfaces, the scene descriptor, and the dependency
-- record; only after reading everything back and confirming the map validates
-- is the completion marker written. Any failure rolls back the map's own subtree
-- and re-raises, never touching the raw ROM dump. All writes go through CacheFs,
-- which confines every path to the version subtree.

local Errors = require("libs.rom.src.Errors")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local MapCacheWriter = {}

local function persist(cacheFs, bundle)
  local mapId = bundle.mapId
  local dir = MapAssetCache.mapDir(mapId)

  -- 1. Shared content-addressed geometry.
  for sha1, batch in pairs(bundle.meshes) do
    cacheFs:write(MapAssetCache.geometryPath(sha1), MeshWriter.encode(batch))
  end
  -- 2. Shared content-addressed textures.
  for sha1, tex in pairs(bundle.textures) do
    cacheFs:write(MapAssetCache.texturePath(sha1), PngWriter.encode(tex.width, tex.height, tex.pixels))
  end
  -- 3. Model descriptors.
  for modelKey, descriptor in pairs(bundle.models) do
    cacheFs:writeLua(MapAssetCache.modelPath(modelKey), descriptor)
  end
  -- 4. Permission grid.
  if #bundle.permissions ~= 2048 then
    Errors.raise(
      "MAP_CACHE_BAD_PERMISSIONS",
      "permission grid is " .. #bundle.permissions .. " bytes, expected 2048",
      { mapId = mapId }
    )
  end
  cacheFs:write(dir .. "/permissions.bin", bundle.permissions)
  -- 5. Terrain surfaces.
  if type(bundle.terrain) ~= "table" or bundle.terrain.schema ~= "g4-terrain-surfaces-v1" then
    Errors.raise("MAP_CACHE_BAD_TERRAIN", "terrain artifact is missing or has the wrong schema", { mapId = mapId })
  end
  cacheFs:writeLua(MapAssetCache.terrainPath(mapId), bundle.terrain)
  -- 6. Neighbor permission and terrain artifacts.
  for landDataMemberId, chunk in pairs(bundle.neighborChunks or {}) do
    if #chunk.permissions ~= 2048 then
      Errors.raise(
        "MAP_CACHE_BAD_NEIGHBOR_PERMISSIONS",
        "neighbor permission grid must be 2048 bytes",
        { mapId = mapId, landDataMemberId = landDataMemberId, size = #chunk.permissions }
      )
    end
    if type(chunk.terrain) ~= "table" or chunk.terrain.schema ~= "g4-terrain-surfaces-v1" then
      Errors.raise(
        "MAP_CACHE_BAD_NEIGHBOR_TERRAIN",
        "neighbor terrain artifact is invalid",
        { mapId = mapId, landDataMemberId = landDataMemberId }
      )
    end
    cacheFs:write(MapAssetCache.neighborPermissionsPath(mapId, landDataMemberId), chunk.permissions)
    cacheFs:writeLua(MapAssetCache.neighborTerrainPath(mapId, landDataMemberId), chunk.terrain)
  end
  -- 7. Scene descriptor. 8. Dependency record.
  cacheFs:writeLua(dir .. "/scene.lua", bundle.scene)
  cacheFs:writeLua(dir .. "/dependencies.lua", bundle.dependencies)

  -- 9. Read back and validate every reference (including model-descriptor
  --    internals) before committing the marker. isReady requires the marker too,
  --    so probe with the intended marker after the marker file is written;
  --    here validate references directly.
  local scene = cacheFs:loadLua(dir .. "/scene.lua")
  if type(scene) ~= "table" then
    Errors.raise("MAP_CACHE_READBACK_FAILED", "scene.lua did not read back as a table", { mapId = mapId })
  end
  for _, path in ipairs(MapAssetCache.referencedPaths(scene, cacheFs)) do
    if not cacheFs:exists(path) then
      Errors.raise("MAP_CACHE_MISSING_ASSET", "referenced asset missing after write: " .. path, { mapId = mapId })
    end
  end

  -- 10. Completion marker, written last.
  cacheFs:write(dir .. "/complete", bundle.marker)
  return bundle.marker
end

-- Write the bundle transactionally. Returns the marker on success; on failure
-- removes the map subtree and re-raises the original structured error.
function MapCacheWriter.write(cacheFs, bundle)
  assert(type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid bundle")
  local ok, result = pcall(persist, cacheFs, bundle)
  if ok then
    return result
  end
  -- Roll back this map's artifacts; leave shared orphans and the raw dump alone.
  pcall(function()
    MapAssetCache.invalidateMap(cacheFs, bundle.mapId)
  end)
  error(result)
end

return MapCacheWriter
