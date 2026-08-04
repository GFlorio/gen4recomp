-- MeshWriter G4M2 encoding: header fields, vertex/index payload layout, color
-- source byte, index width selection, and rejection of empty / malformed batches.

local Assert = require("tests.support.Assert")
local BinaryReader = require("src.import.BinaryReader")
local MeshWriter = require("src.import.MeshWriter")
local Errors = require("src.import.Errors")

local T = {}

local function triangle()
  local function v(x, y, z, source)
    return { x = x, y = y, z = z, u = 0, v = 0, nx = 0, ny = 1, nz = 0,
      r = 255, g = 128, b = 0, a = 255, colorSource = source or 0 }
  end
  return { vertices = { v(0, 0, 0, 0), v(1, 0, 0, 1), v(0, 0, 1, 2) }, indices = { 0, 1, 2 } }
end

function T.header_fields()
  local s = MeshWriter.encode(triangle())
  local r = BinaryReader.new(s, "mesh")
  Assert.equal(r:bytes(0, 4), "G4M2")
  Assert.equal(r:u16le(4), 2)   -- version
  Assert.equal(r:u16le(6), 0)   -- flags
  Assert.equal(r:u32le(8), 3)   -- vertex count
  Assert.equal(r:u32le(12), 3)  -- index count
  Assert.equal(r:u16le(16), 40) -- stride
  Assert.equal(r:u16le(18), 2)  -- index width
  Assert.equal(r:u32le(20), 0)  -- reserved (0x14)
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
  Assert.equal(r:u8(base + 36), 0)      -- v0 colorSource
  Assert.equal(r:u8(base + 40 + 36), 1) -- v1 colorSource
  local idxBase = 24 + 3 * 40
  Assert.equal(r:u16le(idxBase), 0)
  Assert.equal(r:u16le(idxBase + 2), 1)
  Assert.equal(r:u16le(idxBase + 4), 2)
end

function T.rejects_unresolved_color_source()
  local b = triangle(); b.vertices[1].colorSource = nil
  local ok, err = pcall(MeshWriter.encode, b)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MESH_UNRESOLVED_COLOR_SOURCE", "nil source raises")
end

function T.rejects_empty_batch()
  local ok, err = pcall(MeshWriter.encode, { vertices = {}, indices = {} })
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MESH_EMPTY", "empty raises")
end

function T.rejects_non_triangle_index_count()
  local b = triangle(); b.indices = { 0, 1 }
  local ok, err = pcall(MeshWriter.encode, b)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MESH_BAD_INDEX_COUNT", "bad count raises")
end

return T
