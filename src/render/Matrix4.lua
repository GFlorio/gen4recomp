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

local function sub3(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot3(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
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
    s[1], u[1], -f[1], 0,
    s[2], u[2], -f[2], 0,
    s[3], u[3], -f[3], 0,
    -dot3(s, eye), -dot3(u, eye), dot3(f, eye), 1,
  }
end

-- Serializable copy of the 16 components (column-major order).
function Matrix4.toArray(m)
  local a = {}
  for i = 1, 16 do a[i] = m[i] end
  return a
end

return Matrix4
