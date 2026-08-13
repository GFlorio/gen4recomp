-- MapUnits calibration: posScale/tile folding, tile extents at representative
-- indoor and multi-cell map scales, and rejection of degenerate models.

local Assert = require("tests.support.Assert")
local MapUnits = require("romdump.src.digest.MapUnits")
local Errors = require("libs.errors.src.Errors")

local T = {}

function T.to_runtime_folds_posscale_and_tile_size()
  local x, y, z = MapUnits.toRuntime(4, 2, -3, 64)
  Assert.isTrue(math.abs(x - (4 * 64 / 16)) < 1e-9, "x")
  Assert.isTrue(math.abs(y - (2 * 64 / 16)) < 1e-9, "y")
  Assert.isTrue(math.abs(z - (-3 * 64 / 16)) < 1e-9, "z")
end

function T.extent_tiles_matches_elm_scale()
  local bounds = { min = { -4.25, 0, -3.62 }, max = { -0.12, 1, 0 } }
  local ex, ez = MapUnits.extentTiles(bounds, 64)
  Assert.isTrue(ex > 15 and ex < 18, "x extent ~16.5 tiles, got " .. ex)
  Assert.isTrue(ez > 13 and ez < 16, "z extent ~14.5 tiles, got " .. ez)
end

function T.calibration_accepts_elm_bounds()
  local bounds = { min = { -4.25, 0, -3.62 }, max = { -0.12, 1, 0 } }
  Assert.notNil(select(1, MapUnits.assertMapCalibration(bounds, 64, { map = "elm" })))
end

function T.calibration_accepts_multi_cell_map_bounds()
  local bounds = { min = { -4.15, 0, -7.99 }, max = { 4.15, 1.71, 4 } }
  local ex, ez = MapUnits.assertMapCalibration(bounds, 64, { map = "bellchime" })
  Assert.isTrue(ex > 33 and ex < 34, "x extent ~33.2 tiles, got " .. ex)
  Assert.isTrue(ez > 47 and ez < 49, "z extent ~48 tiles, got " .. ez)
end

-- Only the translation column is converted: applying the result to an
-- already-tiled vertex must land where the original matrix would have, before
-- the tile divisor.
function T.matrix_to_tiles_converts_only_the_translation()
  local Matrix4 = require("libs.math.src.Matrix4")
  local m = Matrix4.multiply(Matrix4.translate(32, 16, -48), Matrix4.scale(2, 3, 4))
  local tiled = MapUnits.matrixToTiles(m)
  local bx, by, bz = Matrix4.transformPoint(tiled, 0, 0, 0)
  Assert.equal(bx, 2)
  Assert.equal(by, 1)
  Assert.equal(bz, -3)

  local wx, wy, wz = Matrix4.transformPoint(m, 1, 1, 1)
  local ex, ey, ez = MapUnits.toTiles(wx, wy, wz)
  local ax, ay, az = Matrix4.transformPoint(tiled, MapUnits.toTiles(1, 1, 1))
  Assert.isTrue(
    math.abs(ax - ex) < 1e-9 and math.abs(ay - ey) < 1e-9 and math.abs(az - ez) < 1e-9,
    "tiled matrix on a tiled vertex matches tiling the result"
  )
end

function T.calibration_rejects_degenerate_extent()
  local bounds = { min = { 1, 0, 1 }, max = { 1, 1, 1 } }
  local ok, err = pcall(MapUnits.assertMapCalibration, bounds, 64, { map = "x" })
  Assert.isTrue(not ok, "raises")
  Assert.isTrue(Errors.is(err) and err.code == "MAP_COMPILE_CALIBRATION", "code")
end

return { tests = T }
