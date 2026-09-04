-- The consumer-facing contract for the generated field-camera profiles cache.
-- The romdump writer (FieldCameraCacheWriter) persists to these paths and the
-- runtime consumes them through this module, so a generated path or schema
-- change is a single contract edit.

local FieldCameraCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")

FieldCameraCache.FORMAT = Contract.fieldCamera.cacheFormat
FieldCameraCache.SCHEMA = Contract.fieldCamera.schema

local DIR = "data/generated/field/camera"

function FieldCameraCache.dir()
  return DIR
end

function FieldCameraCache.profilesPath()
  return DIR .. "/profiles.lua"
end

function FieldCameraCache.provenancePath()
  return DIR .. "/provenance.lua"
end

function FieldCameraCache.markerPath()
  return DIR .. "/complete"
end

-- Ready only when the completion marker matches and both generated artifacts
-- exist, so a partial camera build never reads as complete.
function FieldCameraCache.isReady(cacheFs, marker)
  if cacheFs:read(FieldCameraCache.markerPath()) ~= marker then
    return false
  end
  return cacheFs:exists(FieldCameraCache.profilesPath(), "file")
    and cacheFs:exists(FieldCameraCache.provenancePath(), "file")
end

return FieldCameraCache
