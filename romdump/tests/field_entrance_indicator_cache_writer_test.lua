local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MeshWriter = require("libs.assets.src.MeshWriter")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local Writer = require("romdump.src.digest.FieldEntranceIndicatorCacheWriter")

local T = { tests = {} }

T.tests["publishes model marker and referenced mesh under owned effect roots"] = function()
  local oldEncode = MeshWriter.encode
  ---@diagnostic disable-next-line: duplicate-set-field
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local meshPath = FieldEffectAssetCache.geometryPath("mesh-key")
  local bundle = {
    marker = "field-effect-cache-v1:rom:dep",
    model = {},
    manifest = {
      schema = FieldEffectAssetCache.SCHEMA,
      archive = "field_static_models",
      memberId = 85,
      modelPath = FieldEffectAssetCache.modelPath(),
      mesh = meshPath,
      materials = {},
    },
    meshes = { ["mesh-key"] = {} },
    textures = {},
  }
  local ok, err = pcall(Writer.write, cache, bundle)
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(cache:exists(FieldEffectAssetCache.manifestPath(), "file"))
  Assert.isTrue(cache:exists(FieldEffectAssetCache.modelPath(), "file"))
  Assert.equal(cache:read(FieldEffectAssetCache.markerPath()), bundle.marker)
  Assert.equal(cache:read(meshPath), "encoded-mesh")
end

return T
