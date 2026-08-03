-- Builds the runtime transform for a placed building model from its placement
-- record and the model's scale, reproducing the reference field tool's
-- fixed-function matrix call order exactly (scale, translate, rotateZ, rotateY,
-- rotateX) before folding in the shared model-unit/tile conversion. The order is
-- easy to misread, so it is constructed explicitly and never algebraically
-- simplified; a matrix test pins the equivalence. Pure domain module.
--
-- Reference quantities (from the HGSS field building placement):
--   modelScaleFactor = modelScale / 1024
--   translationFactor = 256 / modelScale
-- width/height/length are the low 16 bits of the record's scale words.

local Errors = require("src.import.Errors")
local Matrix4 = require("src.render.Matrix4")
local MapUnits = require("src.import.MapUnits")

local BuildingTransform = {}

local function low16(v) return v % 0x10000 end

-- placement: a BuildingPlacement record. modelScale: the building model's scale.
function BuildingTransform.build(placement, modelScale)
  if modelScale == 0 then
    Errors.raise("BUILDING_TRANSFORM_BAD_SCALE", "model scale must be non-zero",
      { placementIndex = placement.index })
  end

  local modelScaleFactor = modelScale / 1024
  local translationFactor = 256 / modelScale
  local w = low16(placement.scaleRaw.width)
  local h = low16(placement.scaleRaw.height)
  local l = low16(placement.scaleRaw.length)

  local m = Matrix4.scale(modelScaleFactor * w, modelScaleFactor * h, modelScaleFactor * l)
  m = Matrix4.multiply(m, Matrix4.translate(
    placement.position.x * translationFactor / w,
    placement.position.y * translationFactor / h,
    placement.position.z * translationFactor / l))
  m = Matrix4.multiply(m, Matrix4.rotateZ(placement.rotation.z))
  m = Matrix4.multiply(m, Matrix4.rotateY(placement.rotation.y))
  m = Matrix4.multiply(m, Matrix4.rotateX(placement.rotation.x))

  -- Common model-unit -> tile conversion applies to the placement translation
  -- (the geometry itself is already tile-scaled when its mesh is compiled).
  local f = 1 / MapUnits.MODEL_UNITS_PER_TILE
  m[13] = m[13] * f
  m[14] = m[14] * f
  m[15] = m[15] * f
  return m
end

return BuildingTransform
