-- Persists normalized field-camera profiles through the shared staged
-- publication primitive: both deterministic Lua artifacts are written into a
-- disposable staging root, read back there, and only then is the completed
-- stage published with the completion marker last. On any failure the stage is
-- discarded and any previous live camera artifact is left untouched.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")

local FieldCameraCacheWriter = {}

function FieldCameraCacheWriter.isReady(cacheFs, marker)
  return FieldCameraCache.isReady(cacheFs, marker)
end

local function persist(tx, bundle)
  local stage = tx.stage
  stage:writeLua(FieldCameraCache.profilesPath(), bundle.profiles)
  stage:writeLua(FieldCameraCache.provenancePath(), bundle.provenance)
  local profiles, profileErr = stage:loadLua(FieldCameraCache.profilesPath())
  local provenance, provenanceErr = stage:loadLua(FieldCameraCache.provenancePath())
  if not profiles or not provenance then
    Errors.raise(
      "FIELD_CAMERA_CACHE_STALE",
      "camera artifacts failed readback: " .. tostring(profileErr or provenanceErr),
      {}
    )
  end
  assert(profiles.schema == FieldCameraCache.SCHEMA)
  assert(profiles.recordCount == bundle.profiles.recordCount)
  stage:write(FieldCameraCache.markerPath(), bundle.marker)
  tx:publish()
  return bundle.marker
end

function FieldCameraCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.marker, "invalid camera bundle")
  local tx = ArtifactPublisher.begin(cacheFs, "field-cameras", { FieldCameraCache.dir() })
  local ok, result = pcall(persist, tx, bundle)
  if ok then
    return result
  end
  tx:abort()
  error(result)
end

return FieldCameraCacheWriter
