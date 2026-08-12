-- Persists a compiled map bundle to the derived cache through the shared
-- staged publication primitive: the map's own subtree (permission grid, terrain
-- surfaces, neighbor artifacts, scene, dependencies, marker) is written into a
-- disposable staging root, read back and validated there, and only then
-- published over the map's live dir with the marker last. A failure at any
-- point leaves any previous ready map untouched and re-raises, never touching
-- the raw ROM dump.
--
-- Shared content-addressed meshes and textures (and shared model descriptors)
-- are written directly into the live shared roots instead of being staged:
-- they are shared across maps, so a wholesale swap would clobber other maps'
-- artifacts, while content addressing makes a re-write idempotent (same hash,
-- same bytes) and any unreferenced partial garbage from a failed build is
-- inert. The map's readiness never depends on them being absent.

local Errors = require("libs.errors.src.Errors")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PermissionGrid = require("libs.assets.src.PermissionGrid")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local MapCacheWriter = {}

local function persist(cacheFs, tx, bundle)
  local mapId = bundle.mapId
  local dir = MapAssetCache.mapDir(mapId)
  local stage = tx.stage

  -- 1. Shared content-addressed geometry. 2. Shared content-addressed textures.
  -- 3. Shared model descriptors.
  for sha1, batch in pairs(bundle.meshes) do
    cacheFs:write(MapAssetCache.geometryPath(sha1), MeshWriter.encode(batch))
  end
  for sha1, tex in pairs(bundle.textures) do
    cacheFs:write(MapAssetCache.texturePath(sha1), PngWriter.encode(tex.width, tex.height, tex.pixels))
  end
  for modelKey, descriptor in pairs(bundle.models) do
    cacheFs:writeLua(MapAssetCache.modelPath(modelKey), descriptor)
  end
  -- 4. Permission grid.
  if #bundle.permissions ~= PermissionGrid.SIZE then
    Errors.raise(
      "MAP_CACHE_BAD_PERMISSIONS",
      "permission grid is " .. #bundle.permissions .. " bytes, expected " .. PermissionGrid.SIZE,
      { mapId = mapId }
    )
  end
  stage:write(dir .. "/permissions.bin", bundle.permissions)
  -- 5. Terrain surfaces.
  if type(bundle.terrain) ~= "table" or bundle.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
    Errors.raise("MAP_CACHE_BAD_TERRAIN", "terrain artifact is missing or has the wrong schema", { mapId = mapId })
  end
  stage:writeLua(MapAssetCache.terrainPath(mapId), bundle.terrain)
  -- 6. Neighbor permission and terrain artifacts.
  for landDataMemberId, chunk in pairs(bundle.neighborChunks or {}) do
    if #chunk.permissions ~= PermissionGrid.SIZE then
      Errors.raise(
        "MAP_CACHE_BAD_NEIGHBOR_PERMISSIONS",
        "neighbor permission grid must be " .. PermissionGrid.SIZE .. " bytes",
        { mapId = mapId, landDataMemberId = landDataMemberId, size = #chunk.permissions }
      )
    end
    if type(chunk.terrain) ~= "table" or chunk.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      Errors.raise(
        "MAP_CACHE_BAD_NEIGHBOR_TERRAIN",
        "neighbor terrain artifact is invalid",
        { mapId = mapId, landDataMemberId = landDataMemberId }
      )
    end
    stage:write(MapAssetCache.neighborPermissionsPath(mapId, landDataMemberId), chunk.permissions)
    stage:writeLua(MapAssetCache.neighborTerrainPath(mapId, landDataMemberId), chunk.terrain)
  end
  -- 7. Scene descriptor. 8. Dependency record.
  stage:writeLua(dir .. "/scene.lua", bundle.scene)
  stage:writeLua(dir .. "/dependencies.lua", bundle.dependencies)

  -- 9. Read back the staged scene and confirm every referenced asset exists:
  -- map-owned paths in the stage, shared content-addressed paths in the live
  -- shared roots. isReady requires the marker too, so probe with the intended
  -- marker after the marker file is written; here validate references directly.
  local scene = stage:loadLua(dir .. "/scene.lua")
  if type(scene) ~= "table" then
    Errors.raise("MAP_CACHE_READBACK_FAILED", "scene.lua did not read back as a table", { mapId = mapId })
  end
  for _, path in ipairs(MapAssetCache.referencedPaths(scene, cacheFs)) do
    if not stage:exists(path) and not cacheFs:exists(path) then
      Errors.raise("MAP_CACHE_MISSING_ASSET", "referenced asset missing after write: " .. path, { mapId = mapId })
    end
  end

  -- 10. Completion marker, written last, then publish.
  stage:write(dir .. "/complete", bundle.marker)
  tx:publish()
  return bundle.marker
end

-- Write the bundle transactionally. Returns the marker on success; on failure
-- discards the stage and re-raises the original structured error, leaving any
-- previous ready map intact.
function MapCacheWriter.write(cacheFs, bundle)
  assert(type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid bundle")
  local tx = ArtifactPublisher.begin(cacheFs, "map-" .. bundle.mapId, { MapAssetCache.mapDir(bundle.mapId) })
  local ok, result = pcall(persist, cacheFs, tx, bundle)
  if ok then
    return result
  end
  tx:abort()
  error(result)
end

return MapCacheWriter
