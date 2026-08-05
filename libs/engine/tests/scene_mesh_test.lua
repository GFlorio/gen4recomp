-- SceneMesh.decode is the inverse of MeshWriter.encode: round-trip a known
-- batch and confirm every field survives, then exercise each validation guard.

local Assert = require("tests.support.Assert")
local MeshWriter = require("libs.assets.src.MeshWriter")
local SceneMesh = require("libs.engine.src.SceneMesh")

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

-- Two triangles (a quad), colors chosen so /255 round-trips exactly.
local function sampleBatch()
  local vertices = {}
  for i = 0, 3 do
    vertices[i + 1] = {
      x = i, y = i * 2, z = -i, u = 0.5, v = 0.25,
      nx = 0, ny = 1, nz = 0, r = 255, g = 0, b = 128, a = 255, colorSource = i % 3,
    }
  end
  return { vertices = vertices, indices = { 0, 1, 2, 0, 2, 3 } }
end

return {
  ["round-trips a batch through encode/decode"] = function()
    local decoded = SceneMesh.decode(MeshWriter.encode(sampleBatch()))
    Assert.equal(decoded.vertexCount, 4)
    Assert.equal(decoded.indexCount, 6)
    Assert.equal(decoded.indexWidth, 2)
    Assert.deepEqual(decoded.indices, { 0, 1, 2, 0, 2, 3 })
    local v = decoded.vertices[2]
    Assert.equal(v[1], 1)       -- x
    Assert.equal(v[2], 2)       -- y
    Assert.equal(v[3], -1)      -- z
    Assert.equal(v[4], 0.5)     -- u
    Assert.equal(v[6], 0)       -- nx
    Assert.equal(v[7], 1)       -- ny
    Assert.equal(v[9], 1)       -- r 255/255
    Assert.equal(v[11], 128 / 255) -- b
    Assert.equal(v[12], 1)      -- a
    Assert.equal(v[13], 1)      -- colorSource (vertex 2 -> i=1)
  end,

  ["rejects a bad magic"] = function()
    local bytes = MeshWriter.encode(sampleBatch())
    throwsCode("MESH_BAD_MAGIC", function()
      SceneMesh.decode("XXXX" .. bytes:sub(5))
    end)
  end,

  ["rejects a truncated file"] = function()
    local bytes = MeshWriter.encode(sampleBatch())
    throwsCode("MESH_BAD_LENGTH", function()
      SceneMesh.decode(bytes:sub(1, #bytes - 4))
    end)
  end,

  ["rejects trailing bytes"] = function()
    throwsCode("MESH_BAD_LENGTH", function()
      SceneMesh.decode(MeshWriter.encode(sampleBatch()) .. "\0\0\0\0")
    end)
  end,

  ["rejects a header-only truncation"] = function()
    throwsCode("MESH_TOO_SMALL", function()
      SceneMesh.decode("G4M2")
    end)
  end,

  ["rejects a G4M1 file as a stale version"] = function()
    local bytes = MeshWriter.encode(sampleBatch())
    throwsCode("MESH_BAD_MAGIC", function()
      SceneMesh.decode("G4M1" .. bytes:sub(5))
    end)
  end,
}
