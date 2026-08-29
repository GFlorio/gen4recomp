local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MeshWriter = require("libs.assets.src.MeshWriter")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local Writer = require("romdump.src.digest.FieldEntranceIndicatorCacheWriter")
local ModelAsset = require("libs.assets.src.ModelAsset")

local T = { tests = {} }

local function model()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-effect:warp-entrance",
    kind = "static",
    batches = {
      {
        geometry = FieldEffectAssetCache.geometryPath("mesh-key"),
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 5,
        fogEnabled = false,
      },
    },
    materials = {
      {
        id = 0,
        name = "effect",
        texture = FieldEffectAssetCache.texturePath("texture-key"),
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
end

T.tests["publishes model marker and referenced mesh under owned effect roots"] = function()
  local oldEncode = MeshWriter.encode
  ---@diagnostic disable-next-line: duplicate-set-field
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local meshPath = FieldEffectAssetCache.geometryPath("mesh-key")
  local bundle = {
    marker = "field-effect-cache-v3:rom:dep",
    index = {
      schema = "g4-field-effect-index-v1",
      effects = {
        warp_entrance = { path = FieldEffectAssetCache.definitionPath("warp_entrance"), definition = "warp_entrance" },
        tall_grass = { path = FieldEffectAssetCache.definitionPath("tall_grass"), definition = "tall_grass" },
        very_tall_grass = {
          path = FieldEffectAssetCache.definitionPath("very_tall_grass"),
          definition = "very_tall_grass",
        },
      },
    },
    effects = {
      warp_entrance = { model = model(), lifetime = 1 },
      tall_grass = { model = model(), lifetime = 1 },
      very_tall_grass = { model = model(), lifetime = 1 },
    },
    meshes = { ["mesh-key"] = {} },
    textures = { ["texture-key"] = { width = 1, height = 1, pixels = "rgba" } },
  }
  local ok, err = pcall(Writer.write, cache, bundle)
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(cache:exists(FieldEffectAssetCache.indexPath(), "file"))
  Assert.equal(cache:read(FieldEffectAssetCache.markerPath()), bundle.marker)
  Assert.equal(cache:read(meshPath), "encoded-mesh")
end

T.tests["aborts before publication when the canonical model is invalid"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ok = pcall(Writer.write, cache, {
    marker = "field-effect-cache-v3:rom:dep",
    index = { schema = "g4-field-effect-index-v1", effects = {} },
    effects = {},
    model = {},
    meshes = {},
    textures = {},
  })
  Assert.isFalse(ok)
  Assert.isFalse(cache:exists(FieldEffectAssetCache.markerPath(), "file"))
  Assert.isFalse(cache:exists(FieldEffectAssetCache.indexPath(), "file"))
end

return T
