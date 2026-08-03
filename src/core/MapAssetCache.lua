-- Readiness and invalidation for the derived map-asset cache. This cache has its
-- own format version, fully independent of the raw ROM dump: changing it may
-- rebuild derived maps but must never disturb rom-dump.complete, romfs/, or the
-- raw dump indexes. A map is ready only when its completion marker matches
-- exactly and every artifact it references is present, so a partial or stale
-- build never reads as complete. Paths are cache-relative; all IO goes through a
-- CacheFs (which confines every write to the version subtree).

local MapAssetCache = {}

MapAssetCache.FORMAT = "map-cache-v1"

local DERIVED_DATA = "data/generated"
local DERIVED_ASSETS = "assets/generated"

function MapAssetCache.mapDir(mapId)
  return string.format("%s/maps/%04d", DERIVED_DATA, mapId)
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

-- A texture path in scene.materials is stored cache-relative; recover its file.
local function referencedPaths(scene)
  local paths = {}
  for _, b in ipairs(scene.mapBatches or {}) do
    if b.geometry then paths[#paths + 1] = b.geometry end
  end
  for _, m in ipairs(scene.materials or {}) do
    if m.texture then paths[#paths + 1] = m.texture end
  end
  for _, inst in ipairs(scene.buildingInstances or {}) do
    if inst.modelKey then paths[#paths + 1] = MapAssetCache.modelPath(inst.modelKey) end
  end
  return paths
end

-- True only if the marker is exact, scene/dependencies load, permissions.bin is
-- exactly 2048 bytes, and every referenced mesh/texture/model file exists.
function MapAssetCache.isReady(cacheFs, mapId, expectedMarker)
  local dir = MapAssetCache.mapDir(mapId)
  local marker = cacheFs:read(dir .. "/complete")
  if marker ~= expectedMarker then return false end

  local scene = cacheFs:loadLua(dir .. "/scene.lua")
  if type(scene) ~= "table" then return false end
  if not cacheFs:loadLua(dir .. "/dependencies.lua") then return false end

  local perms = cacheFs:getInfo(dir .. "/permissions.bin")
  if not perms or perms.type ~= "file" or perms.size ~= 2048 then return false end

  for _, path in ipairs(referencedPaths(scene)) do
    if not cacheFs:exists(path) then return false end
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
  for _, root in ipairs({ DERIVED_DATA, DERIVED_ASSETS }) do
    assert(root:find("generated", 1, true), "derived root must live under a generated subtree")
    cacheFs:removeTree(root)
  end
  return true
end

return MapAssetCache
