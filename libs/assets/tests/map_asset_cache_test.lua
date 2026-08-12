-- MapAssetCache: path shapes, and readiness gated on an exact marker plus
-- present artifacts.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {}

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function writeReadyMap(c, marker)
  local dir = MapAssetCache.mapDir(61)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, terrain = { file = %q }, mapBatches = {}, materials = {}, buildingInstances = {}, neighbors = {} }\n",
      MapAssetCache.SCENE_SCHEMA,
      MapAssetCache.terrainPath(61)
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.terrainPath(61), "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(dir .. "/permissions.bin", string.rep("\0", 2048))
  c:write(dir .. "/complete", marker)
end

function T.map_dir_is_zero_padded()
  Assert.equal(MapAssetCache.mapDir(61), "data/generated/maps/0061")
  Assert.equal(MapAssetCache.mapDir(60), "data/generated/maps/0060")
end

function T.model_path_is_filesystem_safe()
  Assert.equal(MapAssetCache.modelPath("indoor:22:abcdef"), "data/generated/models/indoor_22_abcdef.lua")
end

function T.not_ready_without_files()
  Assert.isTrue(not MapAssetCache.isReady(cache(), 61, "map-cache-v5:x:61:y"), "no files")
end

function T.ready_only_with_exact_marker_and_files()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  writeReadyMap(c, marker)
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "ready")
  Assert.isTrue(not MapAssetCache.isReady(c, 61, "different-marker"), "stale marker not ready")
end

function T.not_ready_when_referenced_asset_missing()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = { { geometry = 'assets/generated/maps/geometry/abc.g4mesh' } }, materials = {}, buildingInstances = {}, neighbors = {} }\n",
      MapAssetCache.SCENE_SCHEMA
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/permissions.bin", string.rep("\0", 2048))
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing mesh -> not ready")
end

function T.not_ready_with_wrong_permission_size()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  writeReadyMap(c, marker)
  c:write(MapAssetCache.mapDir(61) .. "/permissions.bin", string.rep("\0", 100))
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "wrong perm size -> not ready")
end

function T.not_ready_when_model_descriptor_references_missing_asset()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  local meshPath = "assets/generated/maps/geometry/missing.g4mesh"
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } }, neighbors = {} }\n",
      MapAssetCache.SCENE_SCHEMA,
      modelKey
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/permissions.bin", string.rep("\0", 2048))
  c:write(modelPath, string.format("return { batches = { { geometry = %q } }, materials = {} }\n", meshPath))
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing model-internal geometry -> not ready")
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function T.referenced_paths_includes_neighbor_batches_and_materials()
  local neighborGeometry = "assets/generated/maps/geometry/abc.g4mesh"
  local neighborTexture = "assets/generated/maps/textures/def.png"
  local neighborPermissions = "data/generated/maps/0060/neighbors/3/permissions.bin"
  local neighborTerrain = "data/generated/maps/0060/neighbors/3/terrain.lua"
  local scene = {
    schema = "g4-map-scene-v3",
    mapId = 61,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesZ = 0,
        batches = { { geometry = neighborGeometry, material = 0 } },
        materials = { { id = 0, texture = neighborTexture } },
        collision = { file = neighborPermissions },
        terrain = { file = neighborTerrain },
      },
    },
  }
  local paths = MapAssetCache.referencedPaths(scene, nil)
  Assert.isTrue(contains(paths, neighborGeometry), "missing neighbor geometry path")
  Assert.isTrue(contains(paths, neighborTexture), "missing neighbor texture path")
  Assert.isTrue(contains(paths, neighborPermissions), "missing neighbor permissions path")
  Assert.isTrue(contains(paths, neighborTerrain), "missing neighbor terrain path")
end

function T.world_path_is_stable()
  Assert.equal(type(MapAssetCache.worldPath()), "string")
  Assert.isTrue(MapAssetCache.worldPath():match("world%.lua$") ~= nil)
end

return T
