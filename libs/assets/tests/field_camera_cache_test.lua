-- Tests for FieldCameraCache: the consumer-facing contract for the generated
-- field-camera profiles cache. Both the romdump writer and the runtime
-- consume these paths and the schema; no hardcoded literals live elsewhere.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")

local T = {}

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

function T.contract_paths_are_stable()
  Assert.equal(FieldCameraCache.profilesPath(), "data/generated/field/camera/profiles.lua")
  Assert.equal(FieldCameraCache.provenancePath(), "data/generated/field/camera/provenance.lua")
  Assert.equal(FieldCameraCache.markerPath(), "data/generated/field/camera/complete")
  Assert.equal(FieldCameraCache.SCHEMA, "g4-field-camera-profiles-v1")
end

function T.ready_requires_marker_and_both_artifacts()
  local c = cache()
  Assert.isFalse(FieldCameraCache.isReady(c, "m"), "no files")
  c:write(FieldCameraCache.markerPath(), "m")
  Assert.isFalse(FieldCameraCache.isReady(c, "m"), "marker without artifacts")
  c:write(FieldCameraCache.profilesPath(), "return { schema = 'g4-field-camera-profiles-v1' }\n")
  Assert.isFalse(FieldCameraCache.isReady(c, "m"), "profiles without provenance")
  c:write(FieldCameraCache.provenancePath(), "return {}\n")
  Assert.isTrue(FieldCameraCache.isReady(c, "m"), "ready")
  Assert.isFalse(FieldCameraCache.isReady(c, "other"), "stale marker not ready")
end

return T
