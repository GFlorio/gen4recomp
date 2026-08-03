-- Minimal self-consistent compiled-map bundle for exercising MapCacheWriter and
-- MapAssetCache without the real ROM pipeline: one mesh batch, one 1x1 texture,
-- one model descriptor, and a scene that references all three by their cache
-- paths, plus a 2048-byte permission grid and a marker.

local MapAssetCache = require("src.core.MapAssetCache")

local BundleFixture = {}

function BundleFixture.minimal(mapId)
  mapId = mapId or 61
  local meshSha = "mesh0000000000000000000000000000000000aa"
  local texSha = "tex00000000000000000000000000000000000bb"
  local modelKey = "indoor:1:abc123abc123"

  local function v(x, z)
    return { x = x, y = 0, z = z, u = 0, v = 0, nx = 0, ny = 1, nz = 0, r = 255, g = 255, b = 255, a = 255 }
  end

  local scene = {
    schema = "g4-map-scene-v1",
    mapId = mapId,
    mapBatches = { { geometry = MapAssetCache.geometryPath(meshSha), material = 0, node = 0 } },
    materials = { { id = 0, name = "m0", texture = MapAssetCache.texturePath(texSha) } },
    buildingInstances = { { placementIndex = 0, modelKey = modelKey } },
  }

  return {
    mapId = mapId,
    marker = MapAssetCache.marker("romsha1", mapId, "dephash"),
    scene = scene,
    dependencies = { cacheFormat = MapAssetCache.FORMAT },
    permissions = string.rep("\0", 2048),
    meshes = { [meshSha] = { vertices = { v(0, 0), v(1, 0), v(0, 1) }, indices = { 0, 1, 2 } } },
    textures = { [texSha] = { pixels = string.char(10, 20, 30, 255), width = 1, height = 1 } },
    models = { [modelKey] = { materials = {}, batches = {} } },
  }
end

return BundleFixture
