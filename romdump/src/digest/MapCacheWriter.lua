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
local AssetErrors = require("libs.assets.src.errors")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
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
  -- 4. Collision grid, encoded into the project-owned G4CL asset. The
  -- encoder rejects malformed grids (bad dimensions, missing/wrong cells,
  -- non-boolean blocked), so an invalid bundle never reaches the stage.
  local collisionBytes = CollisionGridAsset.encode(bundle.collision)
  stage:write(dir .. "/collision.g4collision", collisionBytes)
  -- 5. Terrain surfaces.
  if type(bundle.terrain) ~= "table" or bundle.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
    Errors.raise(
      AssetErrors.MAP_CACHE_BAD_TERRAIN,
      "terrain artifact is missing or has the wrong schema",
      { mapId = mapId }
    )
  end
  stage:writeLua(MapAssetCache.terrainPath(mapId), bundle.terrain)
  -- 6. Neighbor collision and terrain artifacts.
  for landDataMemberId, chunk in pairs(bundle.neighborChunks or {}) do
    local neighborCollisionBytes = CollisionGridAsset.encode(chunk.collision)
    if type(chunk.terrain) ~= "table" or chunk.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      Errors.raise(
        AssetErrors.MAP_CACHE_BAD_NEIGHBOR_TERRAIN,
        "neighbor terrain artifact is invalid",
        { mapId = mapId, landDataMemberId = landDataMemberId }
      )
    end
    stage:write(MapAssetCache.neighborCollisionPath(mapId, landDataMemberId), neighborCollisionBytes)
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
    Errors.raise(AssetErrors.MAP_CACHE_READBACK_FAILED, "scene.lua did not read back as a table", { mapId = mapId })
  end
  for _, path in ipairs(MapAssetCache.referencedPaths(scene, cacheFs)) do
    if not stage:exists(path) and not cacheFs:exists(path) then
      Errors.raise(
        AssetErrors.MAP_CACHE_MISSING_ASSET,
        "referenced asset missing after write: " .. path,
        { mapId = mapId }
      )
    end
  end

  -- 10. Completion marker, written last. Publication happens in write()
  -- outside the staging-validation error handler, so a publish failure never
  -- triggers stage cleanup that could delete the last remaining copy of the
  -- previous artifact.
  stage:write(dir .. "/complete", bundle.marker)
  return bundle.marker
end

-- Write the bundle transactionally. Staging/validation failures discard the
-- stage and re-raise; once publish begins the stage is the publisher's
-- recovery material and is never removed here, so any previous ready map
-- stays recoverable.
function MapCacheWriter.write(cacheFs, bundle)
  assert(type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid bundle")
  local tx = ArtifactPublisher.begin(cacheFs, "map-" .. bundle.mapId, { MapAssetCache.mapDir(bundle.mapId) })
  local ok, result = pcall(persist, cacheFs, tx, bundle)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return MapCacheWriter
