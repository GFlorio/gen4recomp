-- Exact HGSS 36-byte field-camera record decoding and unit normalization.

local Assert = require("tests.support.Assert")
local HgssCameraTable = require("romdump.src.digest.HgssCameraTable")

local T = {}

local function u8(v)
  return string.char(v % 256)
end
local function u16(v)
  return u8(v) .. u8(math.floor(v / 256))
end
local function u32(v)
  return u16(v) .. u16(math.floor(v / 65536))
end
local function record(r)
  return u32(r.distance)
    .. u16(r.angleX)
    .. u16(r.angleY or 0)
    .. u16(r.angleZ or 0)
    .. u16(r.unknownAngle or 0)
    .. u8(r.projection)
    .. u8(r.unknownByte or 0)
    .. u16(r.halfAngle)
    .. u32(r.near)
    .. u32(r.far)
    .. u32(r.offsetX or 0)
    .. u32(r.offsetY or 0)
    .. u32(r.offsetZ or 0)
end

local TYPE0 = record({
  distance = 0x0029AEC1,
  angleX = 0xDD62,
  projection = 0,
  halfAngle = 0x05C1,
  near = 0x00096000,
  far = 0x004B0000,
})
local TYPE4 = record({
  distance = 0x0061B89B,
  angleX = 0xDC82,
  projection = 1,
  halfAngle = 0x0281,
  near = 0x00096000,
  far = 0x006C7000,
})

local function near(actual, expected, epsilon)
  Assert.isTrue(
    math.abs(actual - expected) <= epsilon,
    string.format("%.9f not within %.9f of %.9f", actual, epsilon, expected)
  )
end

function T.decodes_frozen_type_zero_and_four_values()
  local filler = record({ distance = 0, angleX = 0, projection = 0, halfAngle = 0, near = 0, far = 0 })
  local bytes = TYPE0 .. filler .. filler .. filler .. TYPE4
  local table = assert(HgssCameraTable.decode(bytes, { tableOffset = 0, recordCount = 5, source = "test-overlay" }))
  Assert.equal(table.schema, "hgss-field-camera-table-v1")
  Assert.equal(table.records[0].raw.distanceRaw, 0x0029AEC1)
  Assert.equal(table.records[0].projection, "perspective")
  Assert.equal(table.records[0].projectionType, "perspective")
  Assert.equal(table.records[0].angleXRaw, -8862)
  near(table.records[0].distanceTiles, 41.682632, 0.000001)
  near(table.records[0].elevationDegrees, 48.680420, 0.000001)
  near(table.records[0].fullVerticalFovDegrees, 16.182861, 0.000001)
  near(table.records[0].fullVerticalFovRadians, math.rad(table.records[0].fullVerticalFovDegrees), 0.000000001)
  Assert.equal(table.records[4].projection, "orthographic")
  near(table.records[4].distanceTiles, 97.721115, 0.000001)
  near(table.records[4].nearTiles, 9.375, 0.000001)
  near(table.records[4].farTiles, 108.4375, 0.000001)
end

function T.preserves_signed_raw_fields_and_normalizes_offsets()
  local bytes = record({
    distance = 0x10000,
    angleX = 0xFFFF,
    angleY = 0x8000,
    angleZ = 0x7FFF,
    unknownAngle = 0xFFFE,
    projection = 0,
    halfAngle = 0x4000,
    near = 0x1000,
    far = 0x2000,
    offsetX = 0xFFFF0000,
    offsetY = 0x10000,
    offsetZ = 0x80000000,
  })
  local profile =
    assert(HgssCameraTable.decode(bytes, { tableOffset = 0, recordCount = 1, source = "signed" })).records[0]
  Assert.equal(profile.raw.angleXRaw, -1)
  Assert.equal(profile.raw.angleYRaw, -32768)
  Assert.equal(profile.raw.unknownAngleField, -2)
  Assert.equal(profile.raw.offsetXRaw, -65536)
  Assert.equal(profile.raw.offsetZRaw, -2147483648)
  Assert.equal(profile.targetOffsetTiles.x, -1)
  Assert.equal(profile.targetOffsetTiles.y, 1)
  Assert.equal(profile.targetOffsetTiles.z, -32768)
end

function T.rejects_bad_projection_and_truncated_table()
  local bad = record({ distance = 0, angleX = 0, projection = 2, halfAngle = 0, near = 0, far = 0 })
  local result, err = HgssCameraTable.decode(bad, { tableOffset = 0, recordCount = 1, source = "bad" })
  Assert.isNil(result)
  Assert.equal(assert(err).code, "FIELD_CAMERA_PROJECTION_UNKNOWN")
  result, err = HgssCameraTable.decode(bad:sub(1, 35), { tableOffset = 0, recordCount = 1, source = "short" })
  Assert.isNil(result)
  Assert.equal(assert(err).code, "FIELD_CAMERA_TABLE_OUT_OF_BOUNDS")
end

return { tests = T }
