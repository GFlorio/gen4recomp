-- 3x3 column-major matrix math used by the renderer's normal-matrix path.
-- Keeps the same indexing convention as Matrix4 (m[col*3 + row + 1]) so the
-- two modules compose cleanly. Pure domain module: no love, arithmetic only.

local Matrix3 = {}

function Matrix3.identity()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- Extract the upper-left 3x3 of a 4x4 column-major matrix.
function Matrix3.from4x4(m)
  return {
    m[1],
    m[2],
    m[3],
    m[5],
    m[6],
    m[7],
    m[9],
    m[10],
    m[11],
  }
end

-- a * b, both 3x3 column-major.
function Matrix3.multiply(a, b)
  local m = {}
  for col = 0, 2 do
    for row = 0, 2 do
      local s = 0
      for k = 0, 2 do
        s = s + a[k * 3 + row + 1] * b[col * 3 + k + 1]
      end
      m[col * 3 + row + 1] = s
    end
  end
  return m
end

function Matrix3.transpose(m)
  return {
    m[1],
    m[4],
    m[7],
    m[2],
    m[5],
    m[8],
    m[3],
    m[6],
    m[9],
  }
end

-- Determinant of a 3x3 matrix.
local function determinant(m)
  return m[1] * (m[5] * m[9] - m[6] * m[8]) - m[4] * (m[2] * m[9] - m[3] * m[8]) + m[7] * (m[2] * m[6] - m[3] * m[5])
end

-- Inverse of a 3x3 matrix, or nil if singular.
function Matrix3.inverse(m)
  local det = determinant(m)
  if math.abs(det) < 1e-12 then
    return nil
  end
  local invDet = 1 / det
  return {
    (m[5] * m[9] - m[6] * m[8]) * invDet,
    (m[3] * m[8] - m[2] * m[9]) * invDet,
    (m[2] * m[6] - m[3] * m[5]) * invDet,
    (m[6] * m[7] - m[4] * m[9]) * invDet,
    (m[1] * m[9] - m[3] * m[7]) * invDet,
    (m[3] * m[4] - m[1] * m[6]) * invDet,
    (m[4] * m[8] - m[5] * m[7]) * invDet,
    (m[2] * m[7] - m[1] * m[8]) * invDet,
    (m[1] * m[5] - m[2] * m[4]) * invDet,
  }
end

-- Transform a 3-vector by a 3x3 matrix.
function Matrix3.transform(m, x, y, z)
  return m[1] * x + m[4] * y + m[7] * z, m[2] * x + m[5] * y + m[8] * z, m[3] * x + m[6] * y + m[9] * z
end

-- Normal matrix: inverse-transpose of the upper 3x3 of (view * model).
-- `model` and `view` are 4x4 column-major matrices. Returns a 3x3 column-major
-- matrix suitable for sending to the vertex shader as a mat3 uniform.
-- A singular model-view transform has no normal matrix; that is invalid input
-- and fails loudly instead of degrading to identity.
function Matrix3.normalMatrix(model, view)
  local mv = Matrix3.multiply(Matrix3.from4x4(view), Matrix3.from4x4(model))
  local inv = Matrix3.inverse(mv)
  assert(inv, "singular model-view transform has no normal matrix")
  return Matrix3.transpose(inv)
end

return Matrix3
