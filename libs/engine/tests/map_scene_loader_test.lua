-- LÖVE tests for MapSceneLoader's sampler-aware image ownership: materials
-- sharing one texture path but sampling it with different wrap modes must
-- receive independent, correctly configured images (regression for the
-- shared-sampler alias), same-sampler materials share one image, and unknown
-- wrap modes fail loudly instead of degrading to clamp. Image/mesh
-- construction needs a graphics context, so those tests skip headless; the
-- unknown-wrap rejection raises before any GPU object is built and runs
-- anywhere.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newMesh
end

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
-- batch per supplied material. Collision is a valid zeroed permissions grid.
local function scene(materials)
  return {
    schema = "g4-map-scene-v3",
    mapId = 1,
    cameraType = 0,
    matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = 0, worldOriginZ = 0 },
    materials = materials,
    mapBatches = {},
    buildingInstances = {},
    neighbors = {},
    collision = { file = "permissions.bin" },
  }
end

-- A cacheFs serving canned bytes for the shared geometry/texture paths plus
-- the permissions grid. luaFiles backs loadLua for model descriptors.
local function cacheFs()
  local geomPath = MapAssetCache.geometryPath("aaaa")
  local texPath = MapAssetCache.texturePath("bbbb")
  local luaFiles = {}
  local blob = {
    [geomPath] = MeshWriter.encode(triangleBatch()),
    [texPath] = PngWriter.encode(1, 1, string.char(255, 0, 0, 255)),
    ["permissions.bin"] = string.rep("\0", 2048),
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
    luaFiles
end

function T.same_texture_with_different_wraps_gets_independent_images()
  if not hasGraphics() then
    return
  end
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
  if not hasGraphics() then
    return
  end
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
  if not hasGraphics() then
    return
  end
  local cache, geomPath, texPath, luaFiles = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  -- The building descriptor shares the scene texture but samples it with
  -- repeat wrap; the scene image and the descriptor image must stay separate.
  s.buildingInstances = {
    {
      modelKey = "building",
      transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    },
  }
  luaFiles[MapAssetCache.modelPath("building")] = {
    schema = "g4-model-descriptor-v1",
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

return T
