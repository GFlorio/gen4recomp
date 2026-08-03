-- BuildingTransform: rejects zero model scale, stays finite for legal inputs
-- (including fractional and negative positions and encoded rotations), and
-- reproduces the exact reference fixed-function call order.

local Assert = require("tests.support.Assert")
local Matrix4 = require("src.render.Matrix4")
local MapUnits = require("src.import.MapUnits")
local BuildingTransform = require("src.data.BuildingTransform")
local Errors = require("src.import.Errors")

local T = {}

local function placement(over)
  local p = {
    index = 0,
    position = { x = 0, y = 0, z = 0 },
    rotation = { x = 0, y = 0, z = 0 },
    scaleRaw = { width = 16, height = 16, length = 16 },
  }
  for k, v in pairs(over or {}) do p[k] = v end
  return p
end

-- Independent re-implementation of the documented reference order.
local function reference(p, modelScale)
  local msf = modelScale / 1024
  local tf = 256 / modelScale
  local w, h, l = p.scaleRaw.width % 0x10000, p.scaleRaw.height % 0x10000, p.scaleRaw.length % 0x10000
  local m = Matrix4.scale(msf * w, msf * h, msf * l)
  m = Matrix4.multiply(m, Matrix4.translate(
    p.position.x * tf / w, p.position.y * tf / h, p.position.z * tf / l))
  m = Matrix4.multiply(m, Matrix4.rotateZ(p.rotation.z))
  m = Matrix4.multiply(m, Matrix4.rotateY(p.rotation.y))
  m = Matrix4.multiply(m, Matrix4.rotateX(p.rotation.x))
  local f = 1 / MapUnits.MODEL_UNITS_PER_TILE
  m[13], m[14], m[15] = m[13] * f, m[14] * f, m[15] * f
  return m
end

local function assertFinite(m)
  for i, c in ipairs(Matrix4.toArray(m)) do
    Assert.isTrue(c == c and c ~= math.huge and c ~= -math.huge, "finite component " .. i)
  end
end

function T.zero_model_scale_errors()
  local ok, err = pcall(BuildingTransform.build, placement(), 0)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "BUILDING_TRANSFORM_BAD_SCALE", "scale 0 raises")
end

function T.default_scale_components_are_16_units()
  -- With modelScale 1024 (factor 1) and encoded scale 16, the diagonal scale is 16.
  local m = BuildingTransform.build(placement(), 1024)
  Assert.isTrue(math.abs(m[1] - 16) < 1e-9, "x scale 16")
  Assert.isTrue(math.abs(m[6] - 16) < 1e-9, "y scale 16")
  Assert.isTrue(math.abs(m[11] - 16) < 1e-9, "z scale 16")
end

function T.finite_for_fractional_and_negative_positions()
  assertFinite(BuildingTransform.build(
    placement({ position = { x = -3.5, y = 1.25, z = 2.0625 } }), 512))
end

function T.finite_for_quarter_turn_rotations()
  for _, r in ipairs({ math.pi / 2, math.pi, 3 * math.pi / 2 }) do
    assertFinite(BuildingTransform.build(placement({ rotation = { x = 0, y = r, z = 0 } }), 1024))
  end
end

function T.matches_reference_call_order()
  local p = placement({
    position = { x = 1, y = 2, z = 3 },
    rotation = { x = math.pi / 6, y = math.pi / 2, z = math.pi },
    scaleRaw = { width = 16, height = 32, length = 8 },
  })
  local got = Matrix4.toArray(BuildingTransform.build(p, 512))
  local ref = Matrix4.toArray(reference(p, 512))
  for i = 1, 16 do Assert.isTrue(math.abs(got[i] - ref[i]) < 1e-6, "component " .. i) end
end

return T
