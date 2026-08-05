-- Tests for Matrix3: extraction, multiplication, inverse-transpose normal
-- matrix under rotation and nonuniform scale, and vector transformation.

local Assert = require("tests.support.Assert")
local Matrix3 = require("libs.engine.src.Matrix3")
local Matrix4 = require("libs.engine.src.Matrix4")

local T = {}

local function approx(a, b) return math.abs(a - b) < 1e-9 end
local function approxVec(a, b)
  return approx(a[1], b[1]) and approx(a[2], b[2]) and approx(a[3], b[3])
end

function T.extracts_upper_3x3()
  local m4 = Matrix4.scale(2, 3, 4)
  local m3 = Matrix3.from4x4(m4)
  Assert.deepEqual(m3, { 2, 0, 0, 0, 3, 0, 0, 0, 4 })
end

function T.identity_is_neutral()
  local x, y, z = Matrix3.transform(Matrix3.identity(), 5, 6, 7)
  Assert.isTrue(approx(x, 5) and approx(y, 6) and approx(z, 7))
end

function T.transpose_swaps_rows_and_columns()
  local m = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
  Assert.deepEqual(Matrix3.transpose(m), { 1, 4, 7, 2, 5, 8, 3, 6, 9 })
end

function T.rotation_normal_matrix_is_transpose()
  -- For pure rotation the inverse is the transpose, so inverse-transpose is the
  -- original rotation matrix.
  local model = Matrix4.rotateY(math.pi / 4)
  local view = Matrix4.identity()
  local n = Matrix3.normalMatrix(model, view)
  local expected = Matrix3.from4x4(model)
  Assert.isTrue(approxVec({ n[1], n[2], n[3] }, { expected[1], expected[2], expected[3] }))
  Assert.isTrue(approxVec({ n[4], n[5], n[6] }, { expected[4], expected[5], expected[6] }))
  Assert.isTrue(approxVec({ n[7], n[8], n[9] }, { expected[7], expected[8], expected[9] }))
end

function T.nonuniform_scale_cancels_with_inverse_transpose()
  -- Scale (2,3,4) followed by its normal matrix should leave a normal unchanged.
  local model = Matrix4.scale(2, 3, 4)
  local view = Matrix4.identity()
  local n = Matrix3.normalMatrix(model, view)
  local tx, ty, tz = Matrix3.transform(n, 1, 1, 1)
  -- The normal matrix for this diagonal scale is diag(1/2, 1/3, 1/4) transposed,
  -- which is the same diagonal matrix.
  Assert.isTrue(approx(tx, 0.5) and approx(ty, 1 / 3) and approx(tz, 0.25))
end

function T.composes_view_and_model()
  -- view * model: rotate model then view. The normal matrix tracks both.
  local model = Matrix4.rotateZ(math.pi / 2)
  local view = Matrix4.rotateX(math.pi / 2)
  local n = Matrix3.normalMatrix(model, view)
  local x, y, z = Matrix3.transform(n, 1, 0, 0)
  -- A model-space +X normal maps to world +Y, then view +Z.
  Assert.isTrue(approxVec({ x, y, z }, { 0, 0, 1 }), "got " .. x .. "," .. y .. "," .. z)
end

return T
