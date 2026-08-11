-- LÖVE tests for MapSceneLoader's sampler-aware image ownership and
-- transactional construction: materials sharing one texture path but sampling
-- it with different wrap modes must receive independent, correctly configured
-- images (regression for the shared-sampler alias), same-sampler materials
-- share one image, and unknown wrap modes fail loudly instead of degrading to
-- clamp. Image construction needs a graphics context, so those tests skip
-- graphics; the unknown-wrap rejection and every post-acquisition failure that
-- releases already-acquired images use an injected fake graphics namespace.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

-- One-triangle batch in the MeshWriter vertex layout.
local function triangleBatch()
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return { vertices = { v(0, 0), v(2, 0), v(0, 2) }, indices = { 0, 1, 2 } }
end

local function material(id, texPath, wrap)
  return {
    id = id,
    name = "mat" .. id,
    texture = texPath,
    wrap = wrap,
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function batch(geomPath, materialId)
  return {
    geometry = geomPath,
    material = materialId,
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 31,
    polygonMode = "modulation",
    lightMask = 0,
    polygonId = 0,
    translucentDepthWrite = false,
    depthEqual = false,
  }
end

-- A minimal current scene: no building instances, no neighbors, one terrain
-- batch per supplied material. Collision is a FieldMapLoader concern.
local function scene(materials)
  return {
    schema = "g4-map-scene-v4",
    mapId = 1,
    cameraType = 0,
    matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = 0, worldOriginZ = 0 },
    materials = materials,
    mapBatches = {},
    buildingInstances = {},
    neighbors = {},
  }
end

-- A cacheFs serving canned bytes for the shared geometry/texture paths.
-- luaFiles backs loadLua for model descriptors. The blob table is returned so
-- tests can corrupt or omit individual files.
local function cacheFs()
  local geomPath = MapAssetCache.geometryPath("aaaa")
  local texPath = MapAssetCache.texturePath("bbbb")
  local luaFiles = {}
  local blob = {
    [geomPath] = MeshWriter.encode(triangleBatch()),
    [texPath] = PngWriter.encode(1, 1, string.char(255, 0, 0, 255)),
  }
  return {
    read = function(_, path)
      return blob[path]
    end,
    loadLua = function(_, path)
      return luaFiles[path]
    end,
  },
    geomPath,
    texPath,
    luaFiles,
    blob
end

-- Injected graphics namespace tracking created images and their release calls,
-- so the image side of a failed load can be observed without a GL context.
local function fakeGraphics()
  local images = {}
  return {
    images = images,
    newImage = function()
      local image = { released = false }
      image.setFilter = function() end
      image.setWrap = function() end
      image.release = function()
        image.released = true
      end
      images[#images + 1] = image
      return image
    end,
  }
end

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

function T.same_texture_with_different_wraps_gets_independent_images()
  local cache, geomPath, texPath = cacheFs()
  local s =
    scene({ material(0, texPath, { x = "clamp", y = "clamp" }), material(1, texPath, { x = "repeat", y = "repeat" }) })
  s.mapBatches = { batch(geomPath, 0), batch(geomPath, 1) }
  local runtime = MapSceneLoader.load(cache, s)
  local clampImage = runtime.mapDraws[1].material.image
  local repeatImage = runtime.mapDraws[2].material.image
  Assert.isTrue(clampImage ~= repeatImage, "shared pixels with different wraps must not alias")
  local ax, ay = clampImage:getWrap()
  Assert.equal(ax, "clamp")
  Assert.equal(ay, "clamp")
  local bx, by = repeatImage:getWrap()
  Assert.equal(bx, "repeat")
  Assert.equal(by, "repeat")
  Assert.equal(runtime.stats.textureCount, 2)
  Assert.equal(runtime.stats.meshCount, 1, "the shared geometry still dedups")
  runtime:release()
end

function T.same_texture_and_wrap_share_one_image()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({
    material(0, texPath, { x = "repeat", y = "clamp" }),
    material(1, texPath, { x = "repeat", y = "clamp" }),
  })
  s.mapBatches = { batch(geomPath, 0), batch(geomPath, 1) }
  local runtime = MapSceneLoader.load(cache, s)
  Assert.equal(runtime.mapDraws[1].material.image, runtime.mapDraws[2].material.image)
  Assert.equal(runtime.stats.textureCount, 1)
  runtime:release()
end

function T.scene_and_building_descriptor_samplers_stay_independent()
  local cache, geomPath, texPath, luaFiles = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  -- The building descriptor shares the scene texture but samples it with
  -- repeat wrap; the scene image and the descriptor image must stay separate.
  s.buildingInstances = {
    {
      placementIndex = 0,
      modelKey = "building",
      transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    },
  }
  luaFiles[MapAssetCache.modelPath("building")] = {
    schema = "g4-model-descriptor-v1",
    kind = "static",
    batches = { batch(geomPath, 0) },
    materials = { material(0, texPath, { x = "repeat", y = "repeat" }) },
  }
  local runtime = MapSceneLoader.load(cache, s)
  Assert.equal(runtime.stats.textureCount, 2)
  local sceneImage = runtime.mapDraws[1].material.image
  local buildingImage = runtime.buildingDraws[1].material.image
  Assert.isTrue(sceneImage ~= buildingImage, "scene and descriptor samplers stay independent")
  runtime:release()
end

function T.unknown_wrap_modes_fail_loudly()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "mirror", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  local ok, err = pcall(MapSceneLoader.load, cache, s)
  Assert.isTrue(
    not ok and Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP",
    "raises GPU_ASSET_UNKNOWN_WRAP: " .. tostring(err.code)
  )
end

-- A scene material image is acquired before the map batches; a missing
-- geometry path fails that later mesh load, and the image must be released.
function T.failed_mesh_load_releases_acquired_images()
  local cache, _, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { { geometry = "missing-geometry.g4mesh", material = 0 } }
  local graphics = fakeGraphics()
  local err = Assert.throws(function()
    MapSceneLoader.load(cache, s, { graphics = graphics })
  end)
  Assert.isTrue(tostring(err):find("missing mesh missing-geometry.g4mesh", 1, true) ~= nil, "mesh failure propagates")
  Assert.equal(#graphics.images, 1, "the scene material image was acquired")
  Assert.equal(graphics.images[1].released, true, "a failed mesh load releases the acquired image")
end

-- A missing model descriptor fails building creation after scene images
-- exist; every acquired image must be released.
function T.failed_descriptor_load_releases_acquired_images()
  local cache, _, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.buildingInstances = { { modelKey = "missing", transform = IDENTITY } }
  local graphics = fakeGraphics()
  local err = Assert.throws(function()
    MapSceneLoader.load(cache, s, { graphics = graphics })
  end)
  Assert.isTrue(tostring(err):find("missing model missing", 1, true) ~= nil, "descriptor failure propagates")
  Assert.equal(#graphics.images, 1)
  Assert.equal(graphics.images[1].released, true, "a failed descriptor load releases the acquired image")
end

-- An unknown wrap inside a building descriptor fails material creation after
-- the scene material image was acquired; the whole pool is released.
function T.unknown_wrap_in_a_building_descriptor_releases_acquired_images()
  local cache, _, texPath, luaFiles = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.buildingInstances = { { modelKey = "building", transform = IDENTITY } }
  luaFiles[MapAssetCache.modelPath("building")] = {
    schema = "g4-model-descriptor-v1",
    batches = {},
    materials = { material(0, texPath, { x = "mirror", y = "clamp" }) },
  }
  local graphics = fakeGraphics()
  local err = Assert.throws(function()
    MapSceneLoader.load(cache, s, { graphics = graphics })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP", "raises GPU_ASSET_UNKNOWN_WRAP")
  Assert.equal(#graphics.images, 1)
  Assert.equal(graphics.images[1].released, true, "the scene image is released with the failed descriptor")
end

-- An unsupported transform mode raises after its mesh was acquired; the load
-- must release the mesh and every image. love-backed (a real mesh is built).
function T.failed_transform_mode_releases_acquired_gpu_objects()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { { geometry = geomPath, material = 0, transformMode = "spooky" } }
  local graphics = fakeGraphics()
  local ok, err = pcall(MapSceneLoader.load, cache, s, { graphics = graphics })
  Assert.isTrue(
    not ok and Errors.is(err) and err.code == "MAP_SCENE_UNSUPPORTED_TRANSFORM_MODE",
    "raises the transform-mode error"
  )
  Assert.equal(#graphics.images, 1)
  Assert.equal(graphics.images[1].released, true, "the acquired image is released with the mesh")
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
