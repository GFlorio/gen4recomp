-- ROM-conformance test for exact field-camera discovery in canonical US
-- HeartGold and SoulSilver dumps. The ROM suite invokes this per version.
-- Raw record decoding facts are pinned against the decoder and discovery
-- modules directly; the compiled runtime profiles carry only normalized
-- records.

local Assert = require("tests.support.Assert")
local FieldCameraCompiler = require("romdump.src.digest.field.FieldCameraCompiler")
local FieldCameraDiscovery = require("romdump.src.digest.field.FieldCameraDiscovery")
local HgssCameraTable = require("romdump.src.digest.field.HgssCameraTable")

local T = {}

local function near(actual, expected, epsilon)
  Assert.isTrue(
    math.abs(actual - expected) <= epsilon,
    string.format("%.9f not within %.9f of %.9f", actual, epsilon, expected)
  )
end

function T.overlay_one_contains_exact_camera_table(romFs)
  local info = assert(romFs:overlayInfo("arm9", 1))
  Assert.equal(info.overlayId, 1)
  local bytes = assert(romFs:readOverlay("arm9", 1))
  Assert.isTrue(#bytes > 0, "overlay 1 is readable")

  -- Raw decoding facts belong to the discovery/decoder pair, not the asset.
  local config = require("romdump.src.config.FieldCameras")[romFs:version()]
  local found = assert(FieldCameraDiscovery.discover(bytes, info, config))
  Assert.equal(found.tableRamAddress, 0x02206478)
  local decoded = assert(HgssCameraTable.decode(bytes, {
    tableOffset = found.tableFileOffset,
    recordCount = config.recordCount,
    source = config.cpu .. "-overlay-" .. config.overlayId,
  }))
  Assert.equal(decoded.recordCount, 17)
  Assert.equal(decoded.records[0].raw.distanceRaw, 0x0029AEC1)
  Assert.equal(decoded.records[0].raw.angleXRaw, -8862)
  Assert.equal(decoded.records[0].raw.projectionTypeRaw, 0)
  Assert.equal(decoded.records[0].raw.perspectiveHalfAngleRaw, 0x05C1)
  near(decoded.records[0].distanceTiles, 41.682632, 0.000001)
  near(decoded.records[0].fullVerticalFovDegrees, 16.182861, 0.000001)
  Assert.equal(decoded.records[4].raw.distanceRaw, 0x0061B89B)
  Assert.equal(decoded.records[4].raw.angleXRaw, -9086)
  Assert.equal(decoded.records[4].raw.projectionTypeRaw, 1)
  Assert.equal(decoded.records[4].raw.perspectiveHalfAngleRaw, 0x0281)
  near(decoded.records[4].distanceTiles, 97.721115, 0.000001)
  near(decoded.records[4].nearTiles, 9.375, 0.000001)
  near(decoded.records[4].farTiles, 108.4375, 0.000001)

  -- The compiled asset exposes the same normalized records without the raw
  -- HGSS block and without embedded overlay provenance.
  local bundle = assert(FieldCameraCompiler.compile(romFs))
  local profiles = bundle.profiles
  Assert.equal(profiles.recordCount, 17)
  Assert.isNil(profiles.source)
  Assert.isNil(profiles.profiles[0].raw)
  near(profiles.profiles[0].distanceTiles, 41.682632, 0.000001)
  Assert.equal(#bundle.provenance.overlaySha1, 40)
end

return require("tests.rom.support.RomSuite").fromFacts(T)
