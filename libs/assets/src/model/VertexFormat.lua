-- The single source of truth for the renderer's vertex layout, matching the
-- G4M2 mesh record attributes (position, texcoord, normal, color,
-- color-source). Kept in one module so a future love upgrade that changes
-- the newMesh format syntax touches one place.
-- The table is plain data (no love calls), so it is safe to require anywhere.
-- Color is carried as float4 in 0..1 to keep the shader read unambiguous.

local G4MeshFormat = require("libs.assets.src.model.G4MeshFormat")

local VertexFormat = {}

-- The renderer's vertex layout version is the batch-format version: the
-- mesh batches it consumes are G4MeshFormat.VERSION, so the two cannot
-- drift apart.
VertexFormat.VERSION = G4MeshFormat.VERSION

VertexFormat.LAYOUT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "float", 4 },
  -- 0 literal RGB, 1 normal-lit, 2 field diffuse (see GxDisplayList.COLOR_SOURCE).
  { "VertexColorSource", "float", 1 },
}

return VertexFormat
