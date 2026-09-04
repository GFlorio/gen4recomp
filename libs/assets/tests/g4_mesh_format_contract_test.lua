-- Static contract for the G4M2 batch-format constants: exactly one owner,
-- libs/assets/src/model/G4MeshFormat.lua (MAGIC/VERSION/STRIDE/HEADER_SIZE/
-- indexWidths), required from every mesh-format module. Textual by intent: a
-- rename that leaves a second source of truth for the magic, version, stride,
-- or header size anywhere in production code fails this check. The behavioral
-- oracle stays the encode/decode round-trip suites (mesh_writer_test.lua,
-- scene_mesh_test.lua); this file pins only the single ownership.

local Assert = require("tests.support.Assert")

local T = {}

local OWNER = "libs/assets/src/model/G4MeshFormat.lua"

-- The three mesh-format modules that must consume the owner and never
-- re-declare the batch constants.
local FILES = {
  "libs/assets/src/model/VertexFormat.lua",
  "libs/assets/src/model/MeshWriter.lua",
  "libs/hgss/src/presentation/SceneMesh.lua",
}

-- Literal duplications each file must be free of: the quoted magic string,
-- and the standalone constant definitions of the batch format.
local FORBIDDEN = {
  ["libs/assets/src/model/VertexFormat.lua"] = { '"G4M2"', "VertexFormat.VERSION = 2" },
  ["libs/assets/src/model/MeshWriter.lua"] = { '"G4M2"', "local VERSION = 2", "local STRIDE = 40" },
  ["libs/hgss/src/presentation/SceneMesh.lua"] = {
    '"G4M2"',
    "local HEADER = 24",
    "local VERSION = 2",
    "local STRIDE = 40",
  },
}

local function read(path)
  local file = assert(io.open(path, "rb"), "cannot read " .. path)
  local content = file:read("*a") ---@type string
  file:close()
  return content
end

function T.g4_mesh_format_owner_declares_the_contract_constants()
  local owner = read(OWNER)
  Assert.notNil(owner, "missing " .. OWNER .. ": the G4M2 constants must live in one owner module")

  -- Loaded through the real require path so the values are the module's own.
  local ok, G4MeshFormat = pcall(require, "libs.assets.src.model.G4MeshFormat")
  Assert.isTrue(ok and type(G4MeshFormat) == "table", "G4MeshFormat must be require-able as a module")
  Assert.equal(G4MeshFormat.MAGIC, "G4M2")
  Assert.equal(G4MeshFormat.VERSION, 2)
  Assert.equal(G4MeshFormat.STRIDE, 40)
  Assert.equal(G4MeshFormat.HEADER_SIZE, 24)
  Assert.isTrue(
    type(G4MeshFormat.indexWidths) == "table"
      and #G4MeshFormat.indexWidths == 2
      and G4MeshFormat.indexWidths[1] == 2
      and G4MeshFormat.indexWidths[2] == 4,
    "indexWidths must be exactly { 2, 4 }"
  )
end

function T.no_mesh_format_module_redeclares_the_batch_constants()
  for _, path in ipairs(FILES) do
    local content = read(path)
    for _, literal in ipairs(FORBIDDEN[path]) do
      Assert.isNil(content:find(literal, 1, true), path .. " must not contain " .. literal)
    end
  end
end

function T.every_mesh_format_module_consumes_the_owner()
  for _, path in ipairs(FILES) do
    local content = read(path)
    Assert.notNil(content:find("G4MeshFormat", 1, true), path .. " must reference the G4MeshFormat owner")
  end
end

return { tests = T }
