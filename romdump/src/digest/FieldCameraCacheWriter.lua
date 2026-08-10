-- Persists normalized field-camera profiles through the shared staged
-- publication primitive: both deterministic Lua artifacts are written into a
-- disposable staging root, read back there, and only then is the completed
-- stage published with the completion marker last. On any failure the stage is
-- discarded and any previous live camera artifact is left untouched.

local Errors = require("libs.rom.src.Errors")
local ArtifactPublisher = require("libs.rom.src.ArtifactPublisher")

local FieldCameraCacheWriter = {}
local DIR = "data/generated/field/camera"

function FieldCameraCacheWriter.profilesPath()
  return DIR .. "/profiles.lua"
end
function FieldCameraCacheWriter.provenancePath()
  return DIR .. "/provenance.lua"
end
function FieldCameraCacheWriter.markerPath()
  return DIR .. "/complete"
end

function FieldCameraCacheWriter.isReady(cacheFs, marker)
  if cacheFs:read(FieldCameraCacheWriter.markerPath()) ~= marker then
    return false
  end
  return cacheFs:exists(FieldCameraCacheWriter.profilesPath(), "file")
    and cacheFs:exists(FieldCameraCacheWriter.provenancePath(), "file")
end

local function persist(tx, bundle)
  local stage = tx.stage
  stage:writeLua(FieldCameraCacheWriter.profilesPath(), bundle.profiles)
  stage:writeLua(FieldCameraCacheWriter.provenancePath(), bundle.provenance)
  local profiles, profileErr = stage:loadLua(FieldCameraCacheWriter.profilesPath())
  local provenance, provenanceErr = stage:loadLua(FieldCameraCacheWriter.provenancePath())
  if not profiles or not provenance then
    Errors.raise(
      "FIELD_CAMERA_CACHE_STALE",
      "camera artifacts failed readback: " .. tostring(profileErr or provenanceErr),
      {}
    )
  end
  assert(profiles.schema == "g4-field-camera-profiles-v1")
  assert(profiles.recordCount == bundle.profiles.recordCount)
  stage:write(FieldCameraCacheWriter.markerPath(), bundle.marker)
  tx:publish()
  return bundle.marker
end

function FieldCameraCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.marker, "invalid camera bundle")
  local tx = ArtifactPublisher.begin(cacheFs, "field-cameras", { DIR })
  local ok, result = pcall(persist, tx, bundle)
  if ok then
    return result
  end
  tx:abort()
  error(result)
end

return FieldCameraCacheWriter
