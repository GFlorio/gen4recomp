-- HGSS BDHC decoding, normalization, and malformed-input coverage.

local Assert = require("tests.support.Assert")
local Builder = require("tests.support.BdhcBuilder")
local HgssBdhc = require("romdump.src.digest.HgssBdhc")

local T = {}

local function near(actual, expected, epsilon)
  Assert.isTrue(
    math.abs(actual - expected) <= (epsilon or 1e-6),
    string.format("expected %.9f, got %.9f", expected, actual)
  )
end

local function decodeError(bytes)
  local terrain, err = HgssBdhc.decode(bytes, { memberId = 0 })
  Assert.isNil(terrain)
  Assert.notNil(err)
  return err
end

function T.decodes_all_arrays_and_normalizes_a_flat_plate()
  local terrain = assert(HgssBdhc.decode(Builder.build({
    points = {
      { raw0 = 7, x = -4, raw4 = 9, z = -3 },
      { raw0 = 11, x = 5, raw4 = 13, z = 6 },
    },
    heights = { Builder.heightRaw(2.5) },
  })))

  Assert.equal(terrain.schema, "hgss-bdhc-v1")
  Assert.deepEqual(terrain.counts, {
    points = 2,
    slopes = 1,
    heights = 1,
    plates = 1,
    strips = 1,
    accessEntries = 1,
  })
  Assert.deepEqual(terrain.points[1], {
    id = 0,
    raw0 = 7,
    x = -4,
    raw4 = 9,
    z = -3,
    localEdgeX = 12,
    localEdgeZ = 13,
  })
  Assert.equal(terrain.slopes[1].nxRaw, 0)
  Assert.equal(terrain.slopes[1].nyRaw, 4096)
  Assert.equal(terrain.slopes[1].nzRaw, 0)
  near(terrain.heights[1].distance, 2.5)
  Assert.deepEqual(terrain.plates[1].normal, { x = 0, y = 1, z = 0 })
  Assert.equal(terrain.plates[1].minX, 12)
  Assert.equal(terrain.plates[1].minZ, 13)
  Assert.equal(terrain.plates[1].maxX, 21)
  Assert.equal(terrain.plates[1].maxZ, 22)
  Assert.equal(terrain.plates[1].slopeClass, "flat")
  Assert.equal(terrain.strips[1].accessEntries[1], 0)
end

function T.classifies_four_ramp_directions_without_approximating_the_plane()
  local terrain = assert(HgssBdhc.decode(Builder.build({
    slopes = {
      { nx = 2896, ny = 2896, nz = 0 },
      { nx = -2896, ny = 2896, nz = 0 },
      { nx = 0, ny = 2896, nz = 2896 },
      { nx = 0, ny = 2896, nz = -2896 },
    },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 1, heightIndex = 0 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 2, heightIndex = 0 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 3, heightIndex = 0 },
    },
  })))
  Assert.equal(terrain.plates[1].slopeClass, "ramp_x")
  Assert.equal(terrain.plates[2].slopeClass, "ramp_x")
  Assert.equal(terrain.plates[3].slopeClass, "ramp_z")
  Assert.equal(terrain.plates[4].slopeClass, "ramp_z")
  near(terrain.plates[1].normal.x, math.sqrt(0.5), 1e-6)
  near(terrain.plates[1].normal.y, math.sqrt(0.5), 1e-6)
end

function T.rejects_bad_magic_truncation_and_trailing_bytes()
  Assert.equal(decodeError(Builder.build({ magic = "NOPE" })).code, "BDHC_BAD_MAGIC")
  local valid = Builder.build()
  Assert.equal(decodeError(valid:sub(1, #valid - 1)).code, "BDHC_TRUNCATED")
  Assert.equal(decodeError(valid .. "\0").code, "BDHC_TRAILING_BYTES")
end

function T.validates_every_index_and_access_range()
  local badPoint = Builder.build({
    plates = { { minPointIndex = 0, maxPointIndex = 2, slopeIndex = 0, heightIndex = 0 } },
  })
  Assert.equal(decodeError(badPoint).code, "BDHC_INDEX_OUT_OF_RANGE")

  local badRange = Builder.build({
    strips = { { maxZ = 16, accessStart = 1, accessCount = 1 } },
  })
  Assert.equal(decodeError(badRange).code, "BDHC_ACCESS_RANGE_INVALID")

  local badAccess = Builder.build({ accessEntries = { 1 } })
  Assert.equal(decodeError(badAccess).code, "BDHC_INDEX_OUT_OF_RANGE")
end

function T.rejects_zero_vertical_normal_and_reversed_bounds()
  local zeroVertical = Builder.build({ slopes = { { nx = 4096, ny = 0, nz = 0 } } })
  Assert.equal(decodeError(zeroVertical).code, "BDHC_VERTICAL_NORMAL_ZERO")
  local reversed = Builder.build({
    points = { { x = 1, z = 1 }, { x = -1, z = -1 } },
  })
  Assert.equal(decodeError(reversed).code, "BDHC_BOUNDS_REVERSED")
end

function T.preserves_zero_area_vertical_sentinels_as_nonwalkable()
  local terrain = assert(HgssBdhc.decode(Builder.build({
    points = { { x = -1, z = 0 }, { x = 1, z = 0 } },
    slopes = { { nx = 0, ny = 0, nz = 4096 } },
  })))
  Assert.isFalse(terrain.plates[1].walkable)
  Assert.equal(terrain.plates[1].normal.z, 1)
end

return { metadata = { layer = "unit" }, tests = T }
