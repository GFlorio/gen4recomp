-- MapAssetCache: path shapes, readiness gated on an exact marker plus present
-- artifacts, and derived-only invalidation that spares the raw dump.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {}

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function writeReadyMap(c, marker)
  local dir = MapAssetCache.mapDir(61)
  c:write(dir .. "/scene.lua", "return { mapBatches = {}, materials = {}, buildingInstances = {} }\n")
  c:write(dir .. "/dependencies.lua", "return {}\n")
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
  Assert.isTrue(not MapAssetCache.isReady(cache(), 61, "map-cache-v3:x:61:y"), "no files")
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
  c:write(dir .. "/scene.lua",
    "return { mapBatches = { { geometry = 'assets/generated/maps/geometry/abc.g4mesh' } }, materials = {}, buildingInstances = {} }\n")
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

function T.invalidate_all_derived_spares_raw_dump()
  local c = cache()
  c:write("rom-dump.complete", "x")
  c:write(MapAssetCache.mapDir(61) .. "/complete", "y")
  c:write("assets/generated/maps/geometry/abc.g4mesh", "mesh")
  MapAssetCache.invalidateAllDerived(c)
  Assert.isTrue(c:exists("rom-dump.complete"), "raw marker preserved")
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(61) .. "/complete"), "derived data removed")
  Assert.isTrue(not c:exists("assets/generated/maps/geometry/abc.g4mesh"), "derived assets removed")
end

function T.invalidate_map_removes_only_that_map()
  local c = cache()
  c:write(MapAssetCache.mapDir(61) .. "/complete", "a")
  c:write(MapAssetCache.mapDir(60) .. "/complete", "b")
  MapAssetCache.invalidateMap(c, 61)
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(61) .. "/complete"), "map 61 gone")
  Assert.isTrue(c:exists(MapAssetCache.mapDir(60) .. "/complete"), "map 60 kept")
end

function T.not_ready_when_model_descriptor_references_missing_asset()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  local meshPath = "assets/generated/maps/geometry/missing.g4mesh"
  c:write(dir .. "/scene.lua", string.format(
    "return { mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } } }\n",
    modelKey))
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/permissions.bin", string.rep("\0", 2048))
  c:write(modelPath, string.format("return { batches = { { geometry = %q } }, materials = {} }\n", meshPath))
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing model-internal geometry -> not ready")
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

function T.referenced_paths_includes_neighbor_batches_and_materials()
  local neighborGeometry = "assets/generated/maps/geometry/abc.g4mesh"
  local neighborTexture = "assets/generated/maps/textures/def.png"
  local scene = {
    neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesZ = 0,
        batches = { { geometry = neighborGeometry, material = 0 } },
        materials = { { id = 0, texture = neighborTexture } },
      },
    },
  }
  local paths = MapAssetCache.referencedPaths(scene, nil)
  Assert.isTrue(contains(paths, neighborGeometry), "missing neighbor geometry path")
  Assert.isTrue(contains(paths, neighborTexture), "missing neighbor texture path")
end

function T.world_path_is_stable()
  Assert.equal(type(MapAssetCache.worldPath()), "string")
  Assert.isTrue(MapAssetCache.worldPath():match("world%.lua$") ~= nil)
end

return T
