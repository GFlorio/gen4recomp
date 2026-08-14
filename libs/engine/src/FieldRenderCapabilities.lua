-- The field-render capability contract: which DS GX visual states the
-- current renderer/compiler pipeline actually has a real code path for.
--
-- This is a description of present behavior, not a target. A state is
-- declared `true` only when an existing production code path handles it --
-- exactly (`libs/engine/src/shaders/map.glsl`, `MapRenderer`) or by a
-- documented approximation (`docs/rendering.md` "Deferred / approximate") --
-- never because the DS ideally supports it or a future story intends to add
-- it. Adding a `true` here without first landing the renderer/compiler code
-- that backs it turns this file into wishful thinking instead of a contract.
--
-- Consumed by the ROM census (tests/rom/field_render_state_census_test.lua)
-- to prove the compiled HGSS field corpus never requires a state this file
-- does not declare; a corpus fact requiring an undeclared state is a real
-- rendering gap, not a bug in this file.

local FieldRenderCapabilities = {}

-- DsPolygonAttr.POLYGON_MODES. map.glsl's u_polygonMode is a 0/1 switch
-- (decal vs. modulation); toon and shadow have no combiner path and are
-- rejected at compile time (MAP_COMPILE_UNSUPPORTED_POLYGON_MODE).
FieldRenderCapabilities.polygonModes = {
  modulation = true,
  decal = true,
  toon = false,
  shadow = false,
}

-- DsPolygonAttr.cullMode results that reach MapRenderer's
-- love.graphics.setMeshCullMode(item.cullMode) unmodified.
FieldRenderCapabilities.cullModes = {
  back = true,
  front = true,
  none = true,
}

-- Raw NSBTX format ids; TextureDecoder.SUPPORTED decodes all seven.
FieldRenderCapabilities.textureFormats = {
  [1] = true,
  [2] = true,
  [3] = true,
  [4] = true,
  [5] = true,
  [6] = true,
  [7] = true,
}

-- AlphaClassifier's four classes; RenderQueue partitions draws into exactly
-- these four passes (docs/rendering.md "Alpha classification").
FieldRenderCapabilities.alphaClasses = {
  opaque = true,
  cutout = true,
  translucent = true,
  wireframe = true,
}

-- depthEqual maps to host `lequal` (docs/rendering.md "Deferred /
-- approximate": exact DS Z/W tolerance is not implemented, but the flag is
-- read and does select a real depth-compare mode).
FieldRenderCapabilities.depthEqual = true

-- Bit-11 translucentDepthWrite toggles the host depth-write mask for
-- translucent draws (MapRenderer's per-item `depthWrite` selection).
FieldRenderCapabilities.translucentDepthWrite = true

-- Fog: `fogEnabled` is decoded and carried as metadata through the compiler
-- (MapAssetCompiler, ModelAssetCompiler, FieldActorModel/StaticModel) but no
-- fog uniform, table, or pass exists in map.glsl or MapRenderer. Not
-- implemented.
FieldRenderCapabilities.fog = false

-- Wireframe: MapRenderer draws a real wireframe pass
-- (love.graphics.setWireframe over the triangulated mesh); geometrically
-- approximate (Story 11 notes triangle diagonals can show) but a real path.
FieldRenderCapabilities.wireframe = true

-- Mirrored repeat: material.flip is decoded and validated
-- (MaterialCompiler, ModelAsset schema) but never read downstream --
-- GpuAssetPool/SceneDescriptor's WRAP_MODES only recognize "clamp" and
-- "repeat". Not implemented.
FieldRenderCapabilities.mirroredRepeat = false

-- Billboard: the whole camera-facing billboard vertex path (u_billboard,
-- u_billboardCenter/Scale, BillboardTransform) is implemented and is how
-- every ordinary field actor draws.
FieldRenderCapabilities.billboard = true

return FieldRenderCapabilities
