-- Transactional writer for the normalized movement-emote billboard model.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldEmoteAssetCache = require("libs.assets.src.FieldEmoteAssetCache")
local ModelAsset = require("libs.assets.src.ModelAsset")

local Writer = {}
function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-emotes", {
    "assets/generated/field/emotes",
    "data/generated/field/emotes",
  })
  local ok, err = pcall(function()
    for sha1, mesh in pairs(bundle.meshes) do
      tx.stage:write(FieldEmoteAssetCache.geometryPath(sha1), MeshWriter.encode(mesh))
    end
    for sha1, texture in pairs(bundle.textures) do
      tx.stage:write(
        FieldEmoteAssetCache.texturePath(sha1),
        PngWriter.encode(texture.width, texture.height, texture.pixels)
      )
    end
    tx.stage:writeLua(FieldEmoteAssetCache.exclamationModelPath(), bundle.model)
    local model = assert(tx.stage:loadLua(FieldEmoteAssetCache.exclamationModelPath()))
    ModelAsset.validate(model)
    for _, path in ipairs(ModelAsset.referencedPaths(model)) do
      assert(tx.stage:exists(path), "field-emote referenced asset is missing: " .. path)
    end
    tx.stage:write(FieldEmoteAssetCache.markerPath(), bundle.marker)
  end)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
end
return Writer
