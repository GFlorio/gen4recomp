-- Encoder for the project's binary mesh batches: one indexed triangle list
-- for a single material/state group, kept compact so generated geometry is
-- not carried as huge Lua vertex tables. All values little-endian.
--
-- Two serialized formats exist (the engine mesh serialization contract,
-- see docs/model-ir.md):
--
--   G4M2 — the legacy static layout, used by the baked map/building path:
--     header (24 bytes): "G4M2", u16 version(2), u16 flags, u32 vertexCount,
--       u32 indexCount, u16 stride(40), u16 indexWidth(2|4), u32 reserved(0)
--     vertices: f32 x,y,z,u,v,nx,ny,nz then u8 r,g,b,a, u8 colorSource,
--       u8 pad[3] (40 bytes each)
--     indices:  u16 (vertexCount <= 65535) or u32, zero-based
--
--   G4M3 — the animation-capable layout: G4M2 plus four joint indices and
--     four joint weights (0..255, 255 = 1.0; the four weights of a skinned
--     vertex sum to 255, and a rigid vertex carries all-zero weights with
--     zero joint indices). Stride 48. The renderer's base vertex layout is
--     unchanged (see libs/assets/src/VertexFormat); joints/weights are read
--     by the skinning path, which needs them only at pose time, not upload
--     time.
--
--   header (24 bytes): "G4M3", u16 version(3), u16 flags, u32 vertexCount,
--     u32 indexCount, u16 stride(48), u16 indexWidth(2|4), u32 reserved(0)
--     vertices: f32 x,y,z,u,v,nx,ny,nz then u8 r,g,b,a, u8 colorSource,
--       u8 pad[3], u8 joint[4], u8 weight[4] (48 bytes each)
--     indices:  u16 (vertexCount <= 65535) or u32, zero-based
--
-- `encode(batch, opts)` emits G4M2 by default; opts.format = "g4m3" emits
-- the animated layout and requires every vertex to carry joints/weights.
-- Pure domain module.

local Errors = require("libs.errors.src.Errors")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local Contract = require("libs.assets.src.DerivedAssetContract")

local MeshWriter = {}

MeshWriter.FORMATS = { g4m2 = true, g4m3 = true }

local MAGIC = Contract.mesh.magic
local VERSION = Contract.mesh.version
local STRIDE = 40

local VERSION3 = 3
local STRIDE3 = 48
local WEIGHT_ONE = 255

local function validateG4m3Vertex(v, vertexIndex)
  local joints, weights = v.joints, v.weights
  if type(joints) ~= "table" or #joints ~= 4 or type(weights) ~= "table" or #weights ~= 4 then
    Errors.raise(
      "MESH_MISSING_SKIN_ATTRIBUTES",
      "G4M3 vertex " .. vertexIndex .. " must carry 4 joints and 4 weights",
      { vertex = vertexIndex }
    )
  end
  local sum = 0
  for i = 1, 4 do
    local j, w = joints[i], weights[i]
    if not (type(j) == "number" and math.floor(j) == j and j >= 0 and j <= 255) then
      Errors.raise(
        "MESH_BAD_JOINT_INDEX",
        "G4M3 vertex " .. vertexIndex .. " joint " .. i .. " is out of range",
        { vertex = vertexIndex, joint = i }
      )
    end
    if not (type(w) == "number" and w >= 0 and w <= WEIGHT_ONE and math.floor(w) == w) then
      Errors.raise(
        "MESH_BAD_JOINT_WEIGHT",
        "G4M3 vertex " .. vertexIndex .. " weight " .. i .. " must be an integer in 0..255",
        { vertex = vertexIndex, joint = i }
      )
    end
    sum = sum + w
  end
  if sum ~= 0 and sum ~= WEIGHT_ONE then
    Errors.raise(
      "MESH_BAD_WEIGHT_SUM",
      "G4M3 vertex " .. vertexIndex .. " weights sum to " .. sum .. ", expected 255 (skinned) or 0 (rigid)",
      { vertex = vertexIndex, sum = sum }
    )
  end
end

-- Producer-side G4M3 contract helper: rigid geometry (Nitro field batches
-- resolve every transform from the pose program and never carry skin data)
-- still must present the four joint/weight pairs the G4M3 layout requires.
-- Vertices that already carry attributes are preserved; `encode` stays the
-- strict gate for anything that reaches it without them.
function MeshWriter.ensureSkinAttributes(vertices)
  for _, vertex in ipairs(vertices) do
    if not vertex.joints then
      vertex.joints = { 0, 0, 0, 0 }
    end
    if not vertex.weights then
      vertex.weights = { 0, 0, 0, 0 }
    end
  end
end

function MeshWriter.encode(batch, opts)
  local vertices, indices = batch.vertices, batch.indices
  if not vertices or #vertices == 0 or not indices or #indices == 0 then
    Errors.raise("MESH_EMPTY", "mesh batch has no vertices or indices", {})
  end
  if #indices % 3 ~= 0 then
    Errors.raise("MESH_BAD_INDEX_COUNT", "index count " .. #indices .. " is not a multiple of 3", { count = #indices })
  end
  local format = (opts and opts.format) or "g4m2"
  if not MeshWriter.FORMATS[format] then
    Errors.raise(
      "MESH_UNKNOWN_FORMAT",
      "mesh format must be g4m2 or g4m3, got " .. tostring(format),
      { format = format }
    )
  end

  local isG4m3 = format == "g4m3"
  local magic = isG4m3 and "G4M3" or MAGIC
  local version = isG4m3 and VERSION3 or VERSION
  local stride = isG4m3 and STRIDE3 or STRIDE
  local indexWidth = (#vertices <= 65535) and 2 or 4

  local w = BinaryWriter.new()
  w:bytes(magic):u16(version):u16(0):u32(#vertices):u32(#indices):u16(stride):u16(indexWidth):u32(0)

  for i, v in ipairs(vertices) do
    local source = v.colorSource
    if source == nil or source < 0 or source > 2 then
      Errors.raise(
        "MESH_UNRESOLVED_COLOR_SOURCE",
        "vertex color source must be 0, 1, or 2, got " .. tostring(source),
        {}
      )
    end
    w:f32(v.x):f32(v.y):f32(v.z):f32(v.u):f32(v.v):f32(v.nx):f32(v.ny):f32(v.nz)
    w:u8(v.r):u8(v.g):u8(v.b):u8(v.a):u8(source):u8(0):u8(0):u8(0)
    if isG4m3 then
      validateG4m3Vertex(v, i)
      for j = 1, 4 do
        w:u8(v.joints[j])
      end
      for j = 1, 4 do
        w:u8(v.weights[j])
      end
    end
  end

  for _, i in ipairs(indices) do
    if indexWidth == 2 then
      w:u16(i)
    else
      w:u32(i)
    end
  end

  return w:tostring()
end

return MeshWriter
