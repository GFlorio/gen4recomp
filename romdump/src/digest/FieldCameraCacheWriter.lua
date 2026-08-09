-- Persists normalized field-camera profiles and provenance, committing the
-- completion marker only after both deterministic Lua artifacts read back.

local Errors = require("libs.rom.src.Errors")

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

local function persist(cacheFs, bundle)
  cacheFs:remove(FieldCameraCacheWriter.markerPath())
  cacheFs:writeLua(FieldCameraCacheWriter.profilesPath(), bundle.profiles)
  cacheFs:writeLua(FieldCameraCacheWriter.provenancePath(), bundle.provenance)
  local profiles, profileErr = cacheFs:loadLua(FieldCameraCacheWriter.profilesPath())
  local provenance, provenanceErr = cacheFs:loadLua(FieldCameraCacheWriter.provenancePath())
  if not profiles or not provenance then
    Errors.raise(
      "FIELD_CAMERA_CACHE_STALE",
      "camera artifacts failed readback: " .. tostring(profileErr or provenanceErr),
      {}
    )
  end
  assert(profiles.schema == "g4-field-camera-profiles-v1")
  assert(profiles.recordCount == bundle.profiles.recordCount)
  cacheFs:write(FieldCameraCacheWriter.markerPath(), bundle.marker)
  return bundle.marker
end

function FieldCameraCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.marker, "invalid camera bundle")
  local ok, result = pcall(persist, cacheFs, bundle)
  if ok then
    return result
  end
  pcall(function()
    cacheFs:removeTree(DIR)
  end)
  error(result)
end

return FieldCameraCacheWriter
