-- Terrain inspector emits deterministic metadata and project-generated plane
-- quads without copying source bytes.

local Assert = require("tests.support.Assert")
local Builder = require("tests.support.BdhcBuilder")
local HgssBdhc = require("romdump.src.digest.HgssBdhc")
local TerrainInspector = require("romdump.src.digest.TerrainInspector")

local T = {}

function T.filters_plate_metadata_and_builds_height_gizmos()
  local terrain = assert(HgssBdhc.decode(Builder.build({
    points = {
      { x = -16, z = -16 },
      { x = 0, z = 16 },
      { x = 0, z = -16 },
      { x = 16, z = 16 },
    },
    heights = { Builder.heightRaw(2) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 2, maxPointIndex = 3, slopeIndex = 0, heightIndex = 0 },
    },
  })))
  local report = TerrainInspector.inspect(terrain, { minX = 16.1, minZ = 0, maxX = 32, maxZ = 32 })
  Assert.equal(report.counts.plates, 2)
  Assert.equal(#report.plates, 1)
  Assert.equal(report.plates[1].id, 1)
  local gizmos = TerrainInspector.gizmos(terrain, report.plates)
  Assert.equal(#gizmos, 1)
  Assert.equal(gizmos[1].surfaceId, 1)
  Assert.equal(#gizmos[1].corners, 4)
  Assert.equal(gizmos[1].corners[1].y, 2)
end

return T
