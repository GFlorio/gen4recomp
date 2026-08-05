-- The single source of truth for the renderer's vertex layout, matching the
-- G4M2 mesh record (position, texcoord, normal, color, color-source). Kept in one module so a
-- future love upgrade that changes the newMesh format syntax touches one place.
-- The table is plain data (no love calls), so it is safe to require anywhere.
-- Color is carried as float4 in 0..1 to keep the shader read unambiguous.

local VertexFormat = {}

VertexFormat.VERSION = 2

VertexFormat.LAYOUT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "float", 4 },
  -- 0 literal RGB, 1 normal-lit, 2 field diffuse (see GxDisplayList.COLOR_SOURCE).
  { "VertexColorSource", "float", 1 },
}

return VertexFormat
