-- Private integration gate for exact field-camera discovery in canonical US
-- HeartGold and SoulSilver dumps. The private runner invokes this per version.

local Assert = require("tests.support.Assert")
local FieldCameraCompiler = require("romdump.src.digest.FieldCameraCompiler")

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

  local bundle = assert(FieldCameraCompiler.compile(romFs))
  local profiles = bundle.profiles
  Assert.equal(profiles.recordCount, 17)
  Assert.equal(profiles.source.tableRamAddress, 0x02206478)
  Assert.equal(profiles.source.overlayId, 1)
  Assert.equal(#profiles.source.overlaySha1, 40)

  local type0 = profiles.profiles[0]
  Assert.equal(type0.raw.distanceRaw, 0x0029AEC1)
  Assert.equal(type0.raw.angleXRaw, -8862)
  Assert.equal(type0.raw.projectionTypeRaw, 0)
  Assert.equal(type0.raw.perspectiveHalfAngleRaw, 0x05C1)
  near(type0.distanceTiles, 41.682632, 0.000001)
  near(type0.fullVerticalFovDegrees, 16.182861, 0.000001)

  local type4 = profiles.profiles[4]
  Assert.equal(type4.raw.distanceRaw, 0x0061B89B)
  Assert.equal(type4.raw.angleXRaw, -9086)
  Assert.equal(type4.raw.projectionTypeRaw, 1)
  Assert.equal(type4.raw.perspectiveHalfAngleRaw, 0x0281)
  near(type4.distanceTiles, 97.721115, 0.000001)
  near(type4.nearTiles, 9.375, 0.000001)
  near(type4.farTiles, 108.4375, 0.000001)
end

return T
