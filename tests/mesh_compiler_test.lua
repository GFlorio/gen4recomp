-- MeshCompiler: posScale + tile calibration folded into positions, attributes
-- and indices carried through, and a missing-shape draw rejected.

local Assert = require("tests.support.Assert")
local MeshCompiler = require("src.import.MeshCompiler")
local Errors = require("src.import.Errors")

local T = {}

local function fakeModel()
  local geom = {
    vertices = {
      { x = 1, y = 0, z = 0, u = 0.5, v = 0.25, nx = 0, ny = 1, nz = 0, r = 255, g = 0, b = 0, a = 255 },
      { x = 0, y = 0, z = 1, u = 0, v = 0, nx = 0, ny = 1, nz = 0, r = 0, g = 255, b = 0, a = 255 },
      { x = 0, y = 0, z = 0, u = 0, v = 0, nx = 0, ny = 1, nz = 0, r = 0, g = 0, b = 255, a = 255 },
    },
    indices = { 0, 1, 2 },
  }
  return {
    info = { posScale = 64 },
    shapes = { { index = 0, geometry = geom } }, -- shapeIndex 0 -> this shape
    sbc = { draws = { { nodeIndex = 0, materialIndex = 3, shapeIndex = 0 } } },
  }
end

function T.folds_posscale_and_tile_scale_into_positions()
  local b = MeshCompiler.compile(fakeModel())
  Assert.equal(#b, 1)
  Assert.equal(b[1].materialIndex, 3)
  Assert.equal(b[1].nodeIndex, 0)
  Assert.isTrue(math.abs(b[1].vertices[1].x - (1 * 64 / 16)) < 1e-9, "x scaled by posScale/16")
  Assert.equal(b[1].vertices[1].u, 0.5) -- uv carried through
  Assert.equal(b[1].vertices[2].g, 255) -- color carried through
  Assert.equal(b[1].indices[1], 0)
  Assert.equal(b[1].indices[3], 2)
end

function T.missing_shape_raises()
  local m = fakeModel()
  m.sbc.draws[1].shapeIndex = 9
  local ok, err = pcall(MeshCompiler.compile, m)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_MISSING_SHAPE", "raises")
end

return T
