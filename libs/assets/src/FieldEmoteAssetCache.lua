-- Strict cache contract for generated field movement-emote indicator models
-- (the billboard drawn above an actor while it performs a decoded emote
-- action, such as the exclamation mark).

local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.ModelAsset")

local FieldEmoteAssetCache = {}
FieldEmoteAssetCache.FORMAT = Contract.fieldEmotes.cacheFormat
local DIR = "data/generated/field/emotes"
local EXCLAMATION_MODEL = DIR .. "/exclamation_model.lua"
local MARKER = DIR .. "/complete"
local ASSET_DIR = "assets/generated/field/emotes"

function FieldEmoteAssetCache.exclamationModelPath()
  return EXCLAMATION_MODEL
end
function FieldEmoteAssetCache.markerPath()
  return MARKER
end
function FieldEmoteAssetCache.geometryPath(sha1)
  return ASSET_DIR .. "/geometry/" .. sha1 .. ".g4mesh"
end
function FieldEmoteAssetCache.texturePath(sha1)
  return ASSET_DIR .. "/textures/" .. sha1 .. ".png"
end
function FieldEmoteAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldEmoteAssetCache.FORMAT, romSha1, depHash)
end

function FieldEmoteAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, model = pcall(cacheFs.loadLua, cacheFs, EXCLAMATION_MODEL)
  if not loaded or type(model) ~= "table" then
    return false
  end
  local valid, err = pcall(ModelAsset.validate, model)
  if not valid then
    return false, err
  end
  local referenced, paths = pcall(ModelAsset.referencedPaths, model)
  if not referenced then
    return false, paths
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path) then
      return false
    end
  end
  return true
end

return FieldEmoteAssetCache
