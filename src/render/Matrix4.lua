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

-- Serializable copy of the 16 components (column-major order).
function Matrix4.toArray(m)
  local a = {}
  for i = 1, 16 do a[i] = m[i] end
  return a
end

return Matrix4
