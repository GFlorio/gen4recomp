-- The single source of truth for the renderer's vertex layout, matching the
-- base attributes shared by the G4M2 and G4M3 mesh records (position, texcoord,
-- normal, color, color-source; the G4M3 joint indices/weights are pose-time
-- data and are not upload attributes). Kept in one module so a future love
-- upgrade that changes the newMesh format syntax touches one place.
-- The table is plain data (no love calls), so it is safe to require anywhere.
-- Color is carried as float4 in 0..1 to keep the shader read unambiguous.

local VertexFormat = {}

local Contract = require("libs.assets.src.DerivedAssetContract")

VertexFormat.VERSION = Contract.mesh.vertexFormatVersion

VertexFormat.LAYOUT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "float", 4 },
  -- 0 literal RGB, 1 normal-lit, 2 field diffuse (see GxDisplayList.COLOR_SOURCE).
  { "VertexColorSource", "float", 1 },
}

return VertexFormat
