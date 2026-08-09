-- MeshWriter G4M2 encoding: header fields, vertex/index payload layout, color
-- source byte, index width selection, and rejection of empty / malformed batches.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local MeshWriter = require("libs.assets.src.MeshWriter")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function triangle()
  local function v(x, y, z, source)
    return {
      x = x,
      y = y,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 128,
      b = 0,
      a = 255,
      colorSource = source or 0,
    }
  end
  return { vertices = { v(0, 0, 0, 0), v(1, 0, 0, 1), v(0, 0, 1, 2) }, indices = { 0, 1, 2 } }
end

local function raisesCode(code, fn, ...)
  local ok, err = pcall(fn, ...)
  Assert.isTrue(not ok and Errors.is(err), "expected " .. code .. " to be raised")
  Assert.equal(err.code, code)
end

function T.header_fields()
  local s = MeshWriter.encode(triangle())
  local r = BinaryReader.new(s, "mesh")
  Assert.equal(r:bytes(0, 4), "G4M2")
  Assert.equal(r:u16le(4), 2) -- version
  Assert.equal(r:u16le(6), 0) -- flags
  Assert.equal(r:u32le(8), 3) -- vertex count
  Assert.equal(r:u32le(12), 3) -- index count
  Assert.equal(r:u16le(16), 40) -- stride
  Assert.equal(r:u16le(18), 2) -- index width
  Assert.equal(r:u32le(20), 0) -- reserved (0x14)
  Assert.equal(#s, 24 + 3 * 40 + 3 * 2)
end

function T.vertex_and_index_payload()
  local r = BinaryReader.new(MeshWriter.encode(triangle()), "mesh")
  local base = 24 -- header is 24 bytes (reserved u32 at 0x14 ends at 0x18)
  Assert.isTrue(math.abs(r:f32le(base) - 0) < 1e-9, "v0.x")
  local r2 = base + 40
  Assert.isTrue(math.abs(r:f32le(r2) - 1) < 1e-9, "v1.x")
  -- color bytes start after 8 f32 (32 bytes): r@+32, g@+33, colorSource@+36.
  Assert.equal(r:u8(base + 32), 255)
  Assert.equal(r:u8(base + 33), 128)
  Assert.equal(r:u8(base + 36), 0) -- v0 colorSource
  Assert.equal(r:u8(base + 40 + 36), 1) -- v1 colorSource
  local idxBase = 24 + 3 * 40
  Assert.equal(r:u16le(idxBase), 0)
  Assert.equal(r:u16le(idxBase + 2), 1)
  Assert.equal(r:u16le(idxBase + 4), 2)
end

function T.rejects_unresolved_color_source()
  local b = triangle()
  b.vertices[1].colorSource = nil
  raisesCode("MESH_UNRESOLVED_COLOR_SOURCE", MeshWriter.encode, b)
end

function T.rejects_empty_batch()
  raisesCode("MESH_EMPTY", MeshWriter.encode, { vertices = {}, indices = {} })
end

function T.rejects_non_triangle_index_count()
  local b = triangle()
  b.indices = { 0, 1 }
  raisesCode("MESH_BAD_INDEX_COUNT", MeshWriter.encode, b)
end

-- ---- G4M3 (animation-capable layout) ----

local function skinnedTriangle()
  local function v(x, joints, weights)
    return { x = x, y = 0, z = 0, u = 0, v = 0, nx = 0, ny = 1, nz = 0,
      r = 255, g = 255, b = 255, a = 255, colorSource = 0,
      joints = joints, weights = weights }
  end
  return {
    vertices = {
      v(0, { 0, 1, 2, 3 }, { 64, 64, 64, 63 }),
      v(1, { 2, 3, 0, 0 }, { 128, 127, 0, 0 }),
      v(2, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }),
    },
    indices = { 0, 1, 2 },
  }
end

function T.g4m3_header_and_stride()
  local s = MeshWriter.encode(skinnedTriangle(), { format = "g4m3" })
  local r = BinaryReader.new(s, "mesh")
  Assert.equal(r:bytes(0, 4), "G4M3")
  Assert.equal(r:u16le(4), 3)   -- version
  Assert.equal(r:u16le(16), 48) -- stride
  Assert.equal(#s, 24 + 3 * 48 + 3 * 2)
end

function T.g4m3_round_trips_skin_attributes()
  local s = MeshWriter.encode(skinnedTriangle(), { format = "g4m3" })
  local r = BinaryReader.new(s, "mesh")
  local base = 24
  Assert.equal(r:u8(base + 40), 0) -- joint 0 of vertex 0
  Assert.equal(r:u8(base + 43), 3) -- joint 3
  Assert.equal(r:u8(base + 44), 64) -- weight 0
  Assert.equal(r:u8(base + 47), 63) -- weight 3
  local base1 = base + 48
  Assert.equal(r:u8(base1 + 40), 2)
  Assert.equal(r:u8(base1 + 44), 128)
  local base2 = base + 96
  Assert.equal(r:u8(base2 + 44), 0, "rigid vertices carry zero weights")
end

function T.g4m3_rejects_bad_skin_attributes()
  local b = skinnedTriangle()
  b.vertices[1].weights = { 64, 64, 64 }
  raisesCode("MESH_MISSING_SKIN_ATTRIBUTES", function() return MeshWriter.encode(b, { format = "g4m3" }) end)

  b = skinnedTriangle()
  b.vertices[1].joints[1] = 300
  raisesCode("MESH_BAD_JOINT_INDEX", function() return MeshWriter.encode(b, { format = "g4m3" }) end)

  b = skinnedTriangle()
  b.vertices[1].weights[1] = 300
  raisesCode("MESH_BAD_JOINT_WEIGHT", function() return MeshWriter.encode(b, { format = "g4m3" }) end)

  b = skinnedTriangle()
  b.vertices[1].weights = { 64, 64, 64, 63 } -- sum 255, fine
  b.vertices[2].weights = { 10, 10, 10, 10 } -- sum 40
  raisesCode("MESH_BAD_WEIGHT_SUM", function() return MeshWriter.encode(b, { format = "g4m3" }) end)
end

function T.g4m3_rejects_unknown_format()
  raisesCode("MESH_UNKNOWN_FORMAT", MeshWriter.encode, triangle(), { format = "g4m9" })
end

return { tests = T }
