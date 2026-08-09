-- Matrix4 column-major math: neutrality of identity, composition order, a known
-- rotation, and the serializable array form.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function approx(a, b)
  return math.abs(a - b) < 1e-9
end

function T.identity_is_neutral()
  local m = Matrix4.multiply(Matrix4.identity(), Matrix4.translate(2, 3, 4))
  local x, y, z = Matrix4.transformPoint(m, 0, 0, 0)
  Assert.isTrue(approx(x, 2) and approx(y, 3) and approx(z, 4), "translate origin")
end

function T.scale_composes_after_translate_on_origin_point()
  -- (scale * translate) applied to origin yields the scaled translation.
  local m = Matrix4.multiply(Matrix4.scale(2, 2, 2), Matrix4.translate(1, 0, 0))
  local x = Matrix4.transformPoint(m, 0, 0, 0)
  Assert.isTrue(approx(x, 2), "scale composes after translate")
end

function T.rotateZ_90_maps_x_to_y()
  local x, y = Matrix4.transformPoint(Matrix4.rotateZ(math.pi / 2), 1, 0, 0)
  Assert.isTrue(approx(x, 0) and approx(y, 1), "rotateZ 90deg: +x -> +y")
end

function T.rotateX_90_maps_y_to_z()
  local _, y, z = Matrix4.transformPoint(Matrix4.rotateX(math.pi / 2), 0, 1, 0)
  Assert.isTrue(approx(y, 0) and approx(z, 1), "rotateX 90deg: +y -> +z")
end

function T.rotateY_90_maps_z_to_x()
  local x, _, z = Matrix4.transformPoint(Matrix4.rotateY(math.pi / 2), 0, 0, 1)
  Assert.isTrue(approx(x, 1) and approx(z, 0), "rotateY 90deg: +z -> +x")
end

function T.toArray_is_16_floats()
  local a = Matrix4.toArray(Matrix4.identity())
  Assert.equal(#a, 16)
  Assert.equal(a[1], 1)
  Assert.equal(a[6], 1)
  Assert.equal(a[11], 1)
  Assert.equal(a[16], 1)
end

function T.lookAt_puts_target_in_front_along_negative_z()
  -- Eye above +Z looking at the origin: the origin lands at (0,0,-distance)
  -- in view space (camera looks down -Z).
  local v = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local x, y, z = Matrix4.transformPoint(v, 0, 0, 0)
  Assert.isTrue(approx(x, 0) and approx(y, 0) and approx(z, -5), "origin in front")
end

-- Full 4-component transform including the perspective w row.
local function project(m, x, y, z)
  local cz = m[3] * x + m[7] * y + m[11] * z + m[15]
  local cw = m[4] * x + m[8] * y + m[12] * z + m[16]
  return cz, cw
end

function T.perspective_maps_near_and_far_planes_to_ndc()
  local p = Matrix4.perspective(math.rad(60), 1.5, 1, 100)
  local nz, nw = project(p, 0, 0, -1)
  local fz, fw = project(p, 0, 0, -100)
  Assert.isTrue(approx(nz / nw, -1), "near plane -> ndc -1")
  Assert.isTrue(approx(fz / fw, 1), "far plane -> ndc +1")
end

function T.orthographic_maps_bounds_to_ndc()
  local p = Matrix4.orthographic(-4, 6, -3, 7, 2, 12)
  local left, bottom, near = Matrix4.transformPoint(p, -4, -3, -2)
  local right, top, far = Matrix4.transformPoint(p, 6, 7, -12)
  Assert.isTrue(approx(left, -1) and approx(bottom, -1) and approx(near, -1), "minimum bounds")
  Assert.isTrue(approx(right, 1) and approx(top, 1) and approx(far, 1), "maximum bounds")
end

return T
