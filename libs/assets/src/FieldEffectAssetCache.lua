-- Strict cache contract for ROM-derived field-effect models. The current
-- contract contains the one normalized model descriptor used by the world
-- renderer and records its source archive/member provenance.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.ModelAsset")

local FieldEffectAssetCache = {}
FieldEffectAssetCache.FORMAT = Contract.fieldEffects.cacheFormat
FieldEffectAssetCache.SCHEMA = Contract.fieldEffects.schema
local DIR = "data/generated/field/effects"
local MANIFEST = DIR .. "/warp_entrance.lua"
local MODEL = DIR .. "/warp_entrance_model.lua"
local MARKER = DIR .. "/complete"
local ASSET_DIR = "assets/generated/field/effects"

function FieldEffectAssetCache.manifestPath()
  return MANIFEST
end
function FieldEffectAssetCache.modelPath()
  return MODEL
end
function FieldEffectAssetCache.markerPath()
  return MARKER
end
function FieldEffectAssetCache.geometryPath(sha1)
  return ASSET_DIR .. "/geometry/" .. sha1 .. ".g4mesh"
end
function FieldEffectAssetCache.texturePath(sha1)
  return ASSET_DIR .. "/textures/" .. sha1 .. ".png"
end
function FieldEffectAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldEffectAssetCache.FORMAT, romSha1, depHash)
end

function FieldEffectAssetCache.validateManifest(manifest)
  if type(manifest) ~= "table" or manifest.schema ~= FieldEffectAssetCache.SCHEMA then
    return false, Errors.new("FIELD_EFFECT_MANIFEST_INVALID", "field-effect manifest schema mismatch", {})
  end
  if manifest.archive ~= "field_static_models" or manifest.memberId ~= 85 then
    return false, Errors.new("FIELD_EFFECT_MANIFEST_INVALID", "warp entrance resource identity is invalid", {})
  end
  if type(manifest.modelPath) ~= "string" or type(manifest.mesh) ~= "string" or type(manifest.materials) ~= "table" then
    return false, Errors.new("FIELD_EFFECT_MANIFEST_INVALID", "normalized model references are missing", {})
  end
  return true
end

function FieldEffectAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(MANIFEST)
  local ok = FieldEffectAssetCache.validateManifest(manifest)
  if not ok then
    return false
  end
  local model = cacheFs:loadLua(MODEL)
  if type(model) ~= "table" then
    return false
  end
  local valid, err = pcall(ModelAsset.validate, model)
  if not valid then
    return false, err
  end
  for _, batch in ipairs(model.batches) do
    if type(batch.geometry) ~= "string" or not cacheFs:exists(batch.geometry) then
      return false
    end
  end
  for _, material in ipairs(model.materials) do
    if material.texture and not cacheFs:exists(material.texture) then
      return false
    end
  end
  return true
end

return FieldEffectAssetCache
