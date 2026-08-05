-- Project-generated diagnostic gizmo meshes (no extracted art): axis-aligned
-- boxes the map shader can draw like any other batch. Used for the debug player
-- prism and the development anchor pins. Vertices carry white vertex colour and
-- per-face normals so the shared lighting term shapes them; the draw colour
-- comes from the material diffuse. love-coupled; build once, never in draw.

local VertexFormat = require("libs.assets.src.VertexFormat")

local Gizmos = {}

-- The six faces as (four corner signs, normal). Corners wind CCW seen from
-- outside so the shared back-face cull keeps them.
local FACES = {
  { n = { 0, 0, 1 }, c = { { -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 } } },
  { n = { 0, 0, -1 }, c = { { 1, -1, -1 }, { -1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 } } },
  { n = { 1, 0, 0 }, c = { { 1, -1, 1 }, { 1, -1, -1 }, { 1, 1, -1 }, { 1, 1, 1 } } },
  { n = { -1, 0, 0 }, c = { { -1, -1, -1 }, { -1, -1, 1 }, { -1, 1, 1 }, { -1, 1, -1 } } },
  { n = { 0, 1, 0 }, c = { { -1, 1, 1 }, { 1, 1, 1 }, { 1, 1, -1 }, { -1, 1, -1 } } },
  { n = { 0, -1, 0 }, c = { { -1, -1, -1 }, { 1, -1, -1 }, { 1, -1, 1 }, { -1, -1, 1 } } },
}

-- A box spanning [-hx,hx] x [y0,y1] x [-hz,hz] (world units). y0/y1 let a marker
-- stand on the floor rather than straddle it. `color` is an optional {r,g,b,a}
-- in 0..1 used as the literal vertex color.
function Gizmos.box(hx, y0, y1, hz, color)
  local cy = (y0 + y1) / 2
  local hy = (y1 - y0) / 2
  local c = color or { 1, 1, 1, 1 }
  local verts, map = {}, {}
  for _, f in ipairs(FACES) do
    local base = #verts
    for _, s in ipairs(f.c) do
      verts[#verts + 1] = {
        s[1] * hx, cy + s[2] * hy, s[3] * hz,
        0, 0,
        f.n[1], f.n[2], f.n[3],
        c[1], c[2], c[3], c[4],
        0, -- literal color source
      }
    end
    map[#map + 1] = base + 1
    map[#map + 1] = base + 2
    map[#map + 1] = base + 3
    map[#map + 1] = base + 1
    map[#map + 1] = base + 3
    map[#map + 1] = base + 4
  end
  local mesh = love.graphics.newMesh(VertexFormat.LAYOUT, verts, "triangles", "static")
  mesh:setVertexMap(map)
  return mesh
end

return Gizmos
