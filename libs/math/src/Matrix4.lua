-- Column-major 4x4 matrix math for building placed-model and camera transforms.
-- Convention matches the DS geometry engine and this project's GxDisplayList
-- decoder: a matrix is a 16-element array indexed m[col*4 + row + 1], and
-- multiply(a, b) yields a*b so transforms compose left-to-right. Pure domain
-- module (no love, arithmetic only) so it is usable from both the asset
-- compiler and, later, the renderer.

local Matrix4 = {}

function Matrix4.identity()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- a * b, column-major.
function Matrix4.multiply(a, b)
  local m = {}
  for col = 0, 3 do
    for row = 0, 3 do
      local s = 0
      for k = 0, 3 do
        s = s + a[k * 4 + row + 1] * b[col * 4 + k + 1]
      end
      m[col * 4 + row + 1] = s
    end
  end
  return m
end

-- Transform a point (implicit w = 1); returns the three transformed components.
function Matrix4.transformPoint(m, x, y, z)
  return m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
    m[3] * x + m[7] * y + m[11] * z + m[15]
end

function Matrix4.scale(sx, sy, sz)
  return { sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0, 0, 0, 0, 1 }
end

function Matrix4.translate(tx, ty, tz)
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, ty, tz, 1 }
end

function Matrix4.rotateX(rad)
  local c, s = math.cos(rad), math.sin(rad)
  return { 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 }
end

function Matrix4.rotateY(rad)
  local c, s = math.cos(rad), math.sin(rad)
  return { c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 }
end

function Matrix4.rotateZ(rad)
  local c, s = math.cos(rad), math.sin(rad)
  return { c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- Right-handed OpenGL-style perspective projection (clip z in [-1, 1]).
-- fovY in radians, aspect = width/height. Column-major.
function Matrix4.perspective(fovY, aspect, near, far)
  local f = 1 / math.tan(fovY / 2)
  local m = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  m[1] = f / aspect
  m[6] = f
  m[11] = (far + near) / (near - far)
  m[12] = -1
  m[15] = (2 * far * near) / (near - far)
  return m
end

-- Right-handed OpenGL-style orthographic projection (clip z in [-1, 1]).
-- Bounds are expressed in camera space. Column-major.
function Matrix4.orthographic(left, right, bottom, top, near, far)
  assert(right ~= left, "orthographic width must be non-zero")
  assert(top ~= bottom, "orthographic height must be non-zero")
  assert(far ~= near, "orthographic depth must be non-zero")
  return {
    2 / (right - left),
    0,
    0,
    0,
    0,
    2 / (top - bottom),
    0,
    0,
    0,
    0,
    -2 / (far - near),
    0,
    -(right + left) / (right - left),
    -(top + bottom) / (top - bottom),
    -(far + near) / (far - near),
    1,
  }
end

local function sub3(a, b)
  return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end
local function dot3(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
local function cross3(a, b)
  return {
    a[2] * b[3] - a[3] * b[2],
    a[3] * b[1] - a[1] * b[3],
    a[1] * b[2] - a[2] * b[1],
  }
end
local function normalize3(v)
  local len = math.sqrt(dot3(v, v))
  assert(len > 0, "cannot normalize a zero-length vector")
  return { v[1] / len, v[2] / len, v[3] / len }
end

-- Right-handed lookAt (gluLookAt). eye/center/up are {x,y,z}. Column-major.
function Matrix4.lookAt(eye, center, up)
  local f = normalize3(sub3(center, eye))
  local s = normalize3(cross3(f, up))
  local u = cross3(s, f)
  return {
    s[1],
    u[1],
    -f[1],
    0,
    s[2],
    u[2],
    -f[2],
    0,
    s[3],
    u[3],
    -f[3],
    0,
    -dot3(s, eye),
    -dot3(u, eye),
    dot3(f, eye),
    1,
  }
end

-- The linear part of a 4x4 as a 4x4 (translation zeroed): the matrix a
-- direction vector transforms by, since the DS vector matrix is 3x3 and
-- never picks up a translation.
function Matrix4.linear(m)
  return {
    m[1],
    m[2],
    m[3],
    0,
    m[5],
    m[6],
    m[7],
    0,
    m[9],
    m[10],
    m[11],
    0,
    0,
    0,
    0,
    1,
  }
end

-- Serializable copy of the 16 components (column-major order).
function Matrix4.toArray(m)
  local a = {}
  for i = 1, 16 do
    a[i] = m[i]
  end
  return a
end

-- Inverse of an affine 4x4 (last row 0,0,0,1): the linear part is inverted
-- by its cofactor matrix, then the translation is mapped back through it.
-- Building placement transforms are always affine, so this is the only shape
-- the runtime inverts.
function Matrix4.invert(m)
  assert(m[4] == 0 and m[8] == 0 and m[12] == 0 and m[16] == 1, "Matrix4.invert requires an affine matrix")
  -- Cofactor matrix of the 3x3 linear part (column-major: inv[i] holds the
  -- transposed cofactors, the inverse when divided by the determinant).
  local a11, a12, a13 = m[1], m[5], m[9]
  local a21, a22, a23 = m[2], m[6], m[10]
  local a31, a32, a33 = m[3], m[7], m[11]
  local det = a11 * (a22 * a33 - a23 * a32) - a12 * (a21 * a33 - a23 * a31) + a13 * (a21 * a32 - a22 * a31)
  assert(det ~= 0, "Matrix4.invert requires a non-singular matrix")
  local invDet = 1 / det
  local b11 = (a22 * a33 - a23 * a32) * invDet
  local b12 = (a13 * a32 - a12 * a33) * invDet
  local b13 = (a12 * a23 - a13 * a22) * invDet
  local b21 = (a23 * a31 - a21 * a33) * invDet
  local b22 = (a11 * a33 - a13 * a31) * invDet
  local b23 = (a13 * a21 - a11 * a23) * invDet
  local b31 = (a21 * a32 - a22 * a31) * invDet
  local b32 = (a12 * a31 - a11 * a32) * invDet
  local b33 = (a11 * a22 - a12 * a21) * invDet
  return {
    b11,
    b12,
    b13,
    0,
    b21,
    b22,
    b23,
    0,
    b31,
    b32,
    b33,
    0,
    -(b11 * m[13] + b21 * m[14] + b31 * m[15]),
    -(b12 * m[13] + b22 * m[14] + b32 * m[15]),
    -(b13 * m[13] + b23 * m[14] + b33 * m[15]),
    1,
  }
end

return Matrix4
