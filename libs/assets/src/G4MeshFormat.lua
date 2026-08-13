-- The single owner of the G4M2 batch-format contract constants (magic,
-- version, stride, header size, index widths), shared by the encoder
-- (MeshWriter), the decoder (SceneMesh), and the vertex-layout contract
-- (VertexFormat). The binary layout itself is documented in MeshWriter and
-- docs/rendering.md; this module only owns the numbers, so a format change
-- touches one place. Pure data, safe to require from the pure domain layers.

local G4MeshFormat = {}

G4MeshFormat.MAGIC = "G4M2"
G4MeshFormat.VERSION = 2
G4MeshFormat.STRIDE = 40
G4MeshFormat.HEADER_SIZE = 24
G4MeshFormat.indexWidths = { 2, 4 }

return G4MeshFormat
