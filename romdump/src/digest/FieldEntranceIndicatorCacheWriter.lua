-- Transactional writer for the normalized directional entrance field effect.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")

local Writer = {}
function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-effects", {
    "assets/generated/field/effects",
    "data/generated/field/effects",
  })
  local ok, err = pcall(function()
    for sha1, mesh in pairs(bundle.meshes) do
      tx.stage:write(FieldEffectAssetCache.geometryPath(sha1), MeshWriter.encode(mesh))
    end
    for sha1, texture in pairs(bundle.textures) do
      tx.stage:write(
        FieldEffectAssetCache.texturePath(sha1),
        PngWriter.encode(texture.width, texture.height, texture.pixels)
      )
    end
    tx.stage:writeLua(FieldEffectAssetCache.modelPath(), bundle.model)
    tx.stage:writeLua(FieldEffectAssetCache.manifestPath(), bundle.manifest)
    assert(tx.stage:loadLua(FieldEffectAssetCache.modelPath()))
    tx.stage:write(FieldEffectAssetCache.markerPath(), bundle.marker)
  end)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
end
return Writer
