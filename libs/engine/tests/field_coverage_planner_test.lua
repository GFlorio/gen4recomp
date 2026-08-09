-- FieldCoveragePlanner tests use synthetic camera facts to prove that visible
-- and prefetched matrix cells are derived from the frustum rather than a fixed
-- neighbour ring.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldCoveragePlanner = require("libs.engine.src.FieldCoveragePlanner")

local T = {}

local function approx(a, b, tolerance)
  return math.abs(a - b) <= (tolerance or 1e-6)
end

local function typeZeroCamera(aspect, zoom)
  local distance = 0x0029AEC1 / 4096 / 16
  local angleX = 0xDD62 * 2 * math.pi / 65536
  local halfFov = 0x05C1 * 2 * math.pi / 65536
  local target = { 0, 0, 0 }
  return {
    eye = {
      x = target[1],
      y = target[2] + math.sin(-angleX) * distance,
      z = target[3] + math.cos(angleX) * distance,
    },
    target = { x = target[1], y = target[2], z = target[3] },
    up = { x = 0, y = 1, z = 0 },
    projectionAspect = aspect,
    zoom = zoom or 1,
    profile = {
      projectionType = "perspective",
      fullVerticalFovRadians = 2 * halfFov,
      nearTiles = 0x00096000 / 4096 / 16,
      farTiles = 0x004B0000 / 4096 / 16,
      distanceTiles = distance,
    },
  }
end

function T.zoomed_out_camera_plans_wider_ground_coverage()
  local canonical = FieldCoveragePlanner.frustumGroundBounds(typeZeroCamera(4 / 3, 1), { minY = 0, maxY = 0 })
  local zoomedOut = FieldCoveragePlanner.frustumGroundBounds(typeZeroCamera(4 / 3, 0.5), { minY = 0, maxY = 0 })
  Assert.isTrue(zoomedOut.minX < canonical.minX)
  Assert.isTrue(zoomedOut.maxX > canonical.maxX)
  Assert.isTrue(zoomedOut.minZ < canonical.minZ)
end

function T.type_zero_ground_footprint_expands_horizontally_at_32_9()
  local canonical = FieldCoveragePlanner.frustumGroundBounds(typeZeroCamera(4 / 3), { minY = 0, maxY = 0 })
  local ultrawide = FieldCoveragePlanner.frustumGroundBounds(typeZeroCamera(32 / 9), { minY = 0, maxY = 0 })

  Assert.isTrue(approx(canonical.minZ, ultrawide.minZ, 1e-5))
  Assert.isTrue(approx(canonical.maxZ, ultrawide.maxZ, 1e-5))
  Assert.isTrue(ultrawide.minX < canonical.minX)
  Assert.isTrue(ultrawide.maxX > canonical.maxX)
end

function T.plans_zero_based_cells_with_prefetch_and_clamping()
  local plan = FieldCoveragePlanner.planBounds({
    minX = 33,
    maxX = 95,
    minZ = 65,
    maxZ = 95,
  }, {
    matrixWidth = 5,
    matrixHeight = 4,
    worldOriginX = 0,
    worldOriginZ = 0,
    cellSize = 32,
    prefetchMargin = 1,
  })

  Assert.deepEqual(plan.cellBounds, { minX = 0, maxX = 3, minZ = 1, maxZ = 3 })
  Assert.equal(#plan.cells, 12)
  Assert.deepEqual(plan.cells[1], { x = 0, z = 1 })
  Assert.deepEqual(plan.cells[#plan.cells], { x = 3, z = 3 })
end

function T.rejects_when_frustum_misses_height_envelope()
  local camera = typeZeroCamera(4 / 3)
  local err = Assert.throws(function()
    FieldCoveragePlanner.frustumGroundBounds(camera, { minY = 100, maxY = 101 })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_COVERAGE_INCOMPLETE")
end

function T.detects_missing_planned_cells()
  local plan = { cells = { { x = 1, z = 2 }, { x = 2, z = 2 } } }
  local err = Assert.throws(function()
    FieldCoveragePlanner.assertAvailable(plan, { ["1:2"] = true })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_COVERAGE_INCOMPLETE")
  Assert.equal(err.context.x, 2)
end

return T
