-- Encoder for the project's G4M2 binary mesh batch: one indexed triangle list
-- for a single material/state group, kept compact so generated geometry is not
-- carried as huge Lua vertex tables. All values little-endian.
--   header (24 bytes): "G4M2", u16 version(2), u16 flags, u32 vertexCount,
--     u32 indexCount, u16 stride(40), u16 indexWidth(2|4), u32 reserved(0)
--   vertices: f32 x,y,z,u,v,nx,ny,nz then u8 r,g,b,a, u8 colorSource, u8 pad[3]
--     (40 bytes each)
--   indices:  u16 (vertexCount <= 65535) or u32, zero-based
-- Pure domain module.

local Errors = require("src.import.Errors")
local BinaryWriter = require("src.import.BinaryWriter")

local MeshWriter = {}

local VERSION = 2
local STRIDE = 40

function MeshWriter.encode(batch)
  local vertices, indices = batch.vertices, batch.indices
  if not vertices or #vertices == 0 or not indices or #indices == 0 then
    Errors.raise("MESH_EMPTY", "mesh batch has no vertices or indices", {})
  end
  if #indices % 3 ~= 0 then
    Errors.raise("MESH_BAD_INDEX_COUNT",
      "index count " .. #indices .. " is not a multiple of 3", { count = #indices })
  end
  local indexWidth = (#vertices <= 65535) and 2 or 4

  local w = BinaryWriter.new()
  w:bytes("G4M2"):u16(VERSION):u16(0):u32(#vertices):u32(#indices):u16(STRIDE):u16(indexWidth):u32(0)

  for _, v in ipairs(vertices) do
    local source = v.colorSource
    if source == nil or source < 0 or source > 2 then
      Errors.raise("MESH_UNRESOLVED_COLOR_SOURCE",
        "vertex color source must be 0, 1, or 2, got " .. tostring(source), {})
    end
    w:f32(v.x):f32(v.y):f32(v.z):f32(v.u):f32(v.v):f32(v.nx):f32(v.ny):f32(v.nz)
    w:u8(v.r):u8(v.g):u8(v.b):u8(v.a):u8(source):u8(0):u8(0):u8(0)
  end

  for _, i in ipairs(indices) do
    if indexWidth == 2 then w:u16(i) else w:u32(i) end
  end

  return w:tostring()
end

return MeshWriter
