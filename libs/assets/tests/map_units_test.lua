-- MapUnits calibration: posScale/tile folding, tile extents at the Elm scale,
-- and rejection of an absurdly-sized model.

local Assert = require("tests.support.Assert")
local MapUnits = require("libs.assets.src.MapUnits")
local Errors = require("libs.rom.src.Errors")

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

function T.calibration_rejects_absurd_extent()
  local bounds = { min = { -100, 0, 0 }, max = { 100, 1, 1 } }
  local ok, err = pcall(MapUnits.assertMapCalibration, bounds, 64, { map = "x" })
  Assert.isTrue(not ok, "raises")
  Assert.isTrue(Errors.is(err) and err.code == "MAP_COMPILE_CALIBRATION", "code")
end

return T
