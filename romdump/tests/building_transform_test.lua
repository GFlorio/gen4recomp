-- BuildingTransform: a plain tile-space TRS. Position (in tiles) lands at the
-- translation column, default scale (1.0) is identity, stretch scales, and the
-- composed order (translate * rotZ * rotY * rotX * scale) is verified against an
-- independent re-implementation. The model's posScale is NOT reapplied here --
-- it is already folded into the compiled mesh.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")
local BuildingTransform = require("romdump.src.digest.BuildingTransform")

local T = {}

local function placement(over)
  local p = {
    index = 0,
    position = { x = 0, y = 0, z = 0 },
    rotation = { x = 0, y = 0, z = 0 },
    scale = { width = 1, height = 1, length = 1 },
  }
  for k, v in pairs(over or {}) do p[k] = v end
  return p
end

-- Independent re-implementation of the intended tile-space TRS order.
local function reference(p)
  local s = p.scale
  local m = Matrix4.translate(p.position.x, p.position.y, p.position.z)
  m = Matrix4.multiply(m, Matrix4.rotateZ(p.rotation.z))
  m = Matrix4.multiply(m, Matrix4.rotateY(p.rotation.y))
  m = Matrix4.multiply(m, Matrix4.rotateX(p.rotation.x))
  m = Matrix4.multiply(m, Matrix4.scale(s.width, s.height, s.length))
  return m
end

local function assertFinite(m)
  for i, c in ipairs(Matrix4.toArray(m)) do
    Assert.isTrue(c == c and c ~= math.huge and c ~= -math.huge, "finite component " .. i)
  end
end

function T.default_scale_is_identity()
  -- scale 1.0 == identity: no extra scaling on top of the tile-sized mesh.
  local m = BuildingTransform.build(placement())
  Assert.isTrue(math.abs(m[1] - 1) < 1e-9, "x scale 1")
  Assert.isTrue(math.abs(m[6] - 1) < 1e-9, "y scale 1")
  Assert.isTrue(math.abs(m[11] - 1) < 1e-9, "z scale 1")
end

function T.position_lands_at_the_translation_column_in_tiles()
  local m = BuildingTransform.build(placement({ position = { x = -14, y = 0, z = -6 } }))
  Assert.isTrue(math.abs(m[13] - (-14)) < 1e-9, "tx")
  Assert.isTrue(math.abs(m[14] - 0) < 1e-9, "ty")
  Assert.isTrue(math.abs(m[15] - (-6)) < 1e-9, "tz")
end

function T.origin_maps_to_position()
  local m = BuildingTransform.build(placement({ position = { x = -3.5, y = 1.25, z = -2.5 } }))
  local x, y, z = Matrix4.transformPoint(m, 0, 0, 0)
  Assert.isTrue(math.abs(x + 3.5) < 1e-9 and math.abs(y - 1.25) < 1e-9 and math.abs(z + 2.5) < 1e-9,
    "model origin sits at the tile position")
end

function T.stretch_scales_a_basis_vector()
  local m = BuildingTransform.build(placement({ scale = { width = 2, height = 1, length = 0.5 } }))
  local x = Matrix4.transformPoint(m, 1, 0, 0)
  Assert.isTrue(math.abs(x - 2) < 1e-9, "width 2 -> 2x on +x")
end

function T.finite_for_quarter_turn_rotations()
  for _, r in ipairs({ math.pi / 2, math.pi, 3 * math.pi / 2 }) do
    assertFinite(BuildingTransform.build(placement({ rotation = { x = 0, y = r, z = 0 } })))
  end
end

function T.matches_reference_call_order()
  local p = placement({
    position = { x = 1, y = 2, z = 3 },
    rotation = { x = math.pi / 6, y = math.pi / 2, z = math.pi },
    scale = { width = 1, height = 2, length = 0.5 },
  })
  local got = Matrix4.toArray(BuildingTransform.build(p))
  local ref = Matrix4.toArray(reference(p))
  for i = 1, 16 do Assert.isTrue(math.abs(got[i] - ref[i]) < 1e-6, "component " .. i) end
end

return T
