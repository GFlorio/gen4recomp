-- Builds the runtime world transform for a placed building instance. The model's
-- own posScale is already folded into its compiled mesh (MeshCompiler via
-- MapUnits), so the mesh arrives in field-tile units, and the land record's
-- position is likewise in field tiles. The instance transform is therefore a
-- plain TRS in tile space: per-instance stretch (the record's scaleRaw w/h/l,
-- where 16 encodes 1.0), then the encoded Z/Y/X rotations, then the tile
-- translation. Composed as translate * rotZ * rotY * rotX * scale, so a vertex
-- is stretched, rotated about the model origin, then placed. Pure domain module.
--
-- This deliberately does NOT use the field tool's raw-geometry factors
-- (modelScale/1024 and 256/modelScale): those position un-prescaled model
-- vertices, and applying them on top of the already-tile-scaled mesh collapsed
-- every building into a sub-tile pile at the origin.

local Matrix4 = require("src.render.Matrix4")

local BuildingTransform = {}

local function low16(v) return v % 0x10000 end

-- placement: a BuildingPlacement record (position in tiles, scaleRaw where
-- 16 == 1.0, rotation in radians).
function BuildingTransform.build(placement)
  local sx = low16(placement.scaleRaw.width) / 16
  local sy = low16(placement.scaleRaw.height) / 16
  local sz = low16(placement.scaleRaw.length) / 16
  local p, r = placement.position, placement.rotation

  local m = Matrix4.translate(p.x, p.y, p.z)
  m = Matrix4.multiply(m, Matrix4.rotateZ(r.z))
  m = Matrix4.multiply(m, Matrix4.rotateY(r.y))
  m = Matrix4.multiply(m, Matrix4.rotateX(r.x))
  m = Matrix4.multiply(m, Matrix4.scale(sx, sy, sz))
  return m
end

return BuildingTransform
