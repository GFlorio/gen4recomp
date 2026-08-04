-- The single source of truth for the renderer's vertex layout, matching the
-- G4M1 mesh record (position, texcoord, normal, color). Kept in one module so a
-- future love upgrade that changes the newMesh format syntax touches one place.
-- The table is plain data (no love calls), so it is safe to require anywhere.
-- Color is carried as float4 in 0..1 to keep the shader read unambiguous.

local VertexFormat = {}

VertexFormat.LAYOUT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "float", 4 },
}

return VertexFormat
