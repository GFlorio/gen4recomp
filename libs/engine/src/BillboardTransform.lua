-- Rebuilds the model matrix of a billboard draw against the live camera. A BB
-- shape cannot be baked at compile time, so MapAssetCompiler ships its geometry
-- in billboard-local space plus the position matrix the SBC command captured
-- (`baseTransform`, already composed with any placement transform); this module
-- turns that pair into the matrix the DS would have installed.
--
-- NitroSystem g3d/src/sbc.c NNSi_G3dFuncSbc_BB reads the matrix in force, then
-- loads the position matrix with the translation of that matrix expressed in view
-- space and scales it by the magnitude of each of its three basis vectors. The
-- captured rotation is discarded, and no lookAt is involved: in view space the
-- billboard's orientation is simply the identity. Undoing the view rotation gives
-- the world-space equivalent
--
--   translate(base translation) * inverse(view rotation) * scale(base scale)
--
-- Non-uniform base scale therefore stretches along camera axes, exactly as the DS
-- MTX_SCALE that follows the load does. Pure domain module: no love dependency.

local BillboardTransform = {}

local function columnMagnitude(m, col)
  local a, b, c = m[col * 4 + 1], m[col * 4 + 2], m[col * 4 + 3]
  return math.sqrt(a * a + b * b + c * c)
end

-- `base` and `viewMatrix` are 16-element column-major matrices; the view matrix's
-- linear part must be a rotation, which is true of every field camera, so its
-- inverse is its transpose. Returns a new 16-element matrix.
function BillboardTransform.resolve(base, viewMatrix)
  assert(#base == 16 and #viewMatrix == 16, "resolve needs two 4x4 matrices")
  local sx = columnMagnitude(base, 0)
  local sy = columnMagnitude(base, 1)
  local sz = columnMagnitude(base, 2)

  -- transpose(view rotation) scaled per column, then the base translation. Column
  -- j of the rotation transpose is row j of the rotation, i.e. viewMatrix[j+1],
  -- viewMatrix[j+5], viewMatrix[j+9].
  return {
    viewMatrix[1] * sx,
    viewMatrix[5] * sx,
    viewMatrix[9] * sx,
    0,
    viewMatrix[2] * sy,
    viewMatrix[6] * sy,
    viewMatrix[10] * sy,
    0,
    viewMatrix[3] * sz,
    viewMatrix[7] * sz,
    viewMatrix[11] * sz,
    0,
    base[13],
    base[14],
    base[15],
    1,
  }
end

return BillboardTransform
