-- Decoder for the project's G4M2 binary mesh batch (see libs/assets/src/MeshWriter),
-- the inverse of that encoder. Splits cleanly: decode() is pure and validates a
-- batch into plain vertex/index arrays (usable under bare LuaJIT and testable
-- without love); build() turns a decoded batch into a persistent love Mesh and
-- is the only love-coupled entry point. Vertices come out in the render vertex
-- layout order (x,y,z, u,v, nx,ny,nz, r,g,b,a, colorSource) with colors
-- normalized to 0..1 and colorSource kept as a raw 0/1/2 float; indices stay
-- zero-based as stored, and build() rebases them to love's 1-based vertex map.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local VertexFormat = require("libs.assets.src.VertexFormat")

local SceneMesh = {}

local MAGIC = "G4M2"
local VERSION = 2
local STRIDE = 40
local HEADER = 24 -- "G4M2", u16 ver, u16 flags, u32 vcount, u32 icount, u16 stride, u16 iwidth, u32 reserved

local function isFinite(n)
  return n == n and n ~= math.huge and n ~= -math.huge
end

-- Validate and unpack a G4M2 batch into { vertexCount, indexCount, vertices,
-- indices }. Raises a structured error on any malformed field. Pure.
function SceneMesh.decode(bytes, context)
  assert(type(bytes) == "string", "SceneMesh.decode requires a string")
  if #bytes < HEADER then
    Errors.raise("MESH_TOO_SMALL", "mesh shorter than header", { size = #bytes, source = context })
  end
  local r = BinaryReader.new(bytes, "g4mesh")
  if r:ascii(0, 4) ~= MAGIC then
    Errors.raise("MESH_BAD_MAGIC", "expected G4M2 magic", { source = context })
  end
  local version = r:u16le(4)
  if version ~= VERSION then
    Errors.raise("MESH_BAD_VERSION", "unsupported mesh version " .. version, { source = context })
  end
  local vertexCount = r:u32le(8)
  local indexCount = r:u32le(12)
  local stride = r:u16le(16)
  local indexWidth = r:u16le(18)
  if stride ~= STRIDE then
    Errors.raise("MESH_BAD_STRIDE", "expected stride 40, got " .. stride, { source = context })
  end
  if indexWidth ~= 2 and indexWidth ~= 4 then
    Errors.raise("MESH_BAD_INDEX_WIDTH", "index width must be 2 or 4, got " .. indexWidth, { source = context })
  end
  if indexCount % 3 ~= 0 then
    Errors.raise("MESH_BAD_INDEX_COUNT", "index count not a multiple of 3: " .. indexCount, { source = context })
  end

  local expected = HEADER + vertexCount * STRIDE + indexCount * indexWidth
  if expected ~= #bytes then
    Errors.raise("MESH_BAD_LENGTH", "expected " .. expected .. " bytes, got " .. #bytes, { source = context })
  end

  local vertices = {}
  local off = HEADER
  for i = 1, vertexCount do
    local x, y, z = r:f32le(off), r:f32le(off + 4), r:f32le(off + 8)
    local u, v = r:f32le(off + 12), r:f32le(off + 16)
    local nx, ny, nz = r:f32le(off + 20), r:f32le(off + 24), r:f32le(off + 28)
    for _, n in ipairs({ x, y, z, u, v, nx, ny, nz }) do
      if not isFinite(n) then
        Errors.raise("MESH_NONFINITE", "non-finite vertex component at vertex " .. i, { source = context })
      end
    end
    local red = r:u8(off + 32) / 255
    local green = r:u8(off + 33) / 255
    local blue = r:u8(off + 34) / 255
    local alpha = r:u8(off + 35) / 255
    local colorSource = r:u8(off + 36)
    if colorSource > 2 then
      Errors.raise("MESH_BAD_COLOR_SOURCE", "color source out of range at vertex " .. i, { source = context })
    end
    vertices[i] = { x, y, z, u, v, nx, ny, nz, red, green, blue, alpha, colorSource }
    off = off + STRIDE
  end

  local indices = {}
  for i = 1, indexCount do
    local value = (indexWidth == 2) and r:u16le(off) or r:u32le(off)
    if value >= vertexCount then
      Errors.raise(
        "MESH_INDEX_OUT_OF_RANGE",
        "index " .. value .. " >= vertex count " .. vertexCount,
        { source = context }
      )
    end
    indices[i] = value
    off = off + indexWidth
  end

  return {
    vertexCount = vertexCount,
    indexCount = indexCount,
    indexWidth = indexWidth,
    vertices = vertices,
    indices = indices,
  }
end

-- Build a persistent, static love Mesh from a decoded batch. Rebases the
-- zero-based file indices to love's 1-based vertex map. love-coupled.
function SceneMesh.build(decoded)
  local mesh = love.graphics.newMesh(VertexFormat.LAYOUT, decoded.vertices, "triangles", "static")
  local map = {}
  for i = 1, decoded.indexCount do
    map[i] = decoded.indices[i] + 1
  end
  mesh:setVertexMap(map)
  return mesh
end

return SceneMesh
