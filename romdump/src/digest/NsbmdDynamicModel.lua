-- NsbmdDynamicModel: the digest-side compile of a decoded NSBMD model into
-- the animation-capable (dynamic) model descriptor pieces.
--
--   result = {
--     program = <NsbmdTransformProgram>,        -- the pose evaluator's input
--     meshes = <MeshCompiler.compileDynamic>,   -- per-draw-segment geometry
--     materials = { { id, name, baseColor, colors, alphaMode, doubleSided,
--       polygonAlpha, texMtxMode, srt, texWidth, texHeight } },
--   }
--
-- The meshes carry their transform sources ("draw" or a matrix-stack slot)
-- and the per-segment polygon-attr word; the runtime NitroPoseBackend
-- resolves the sources against the program each frame, so the geometry is
-- compiled once and only the matrices move. MapAssetCompiler turns the
-- segments into content-addressed .g4mesh assets and stamps the descriptor
-- batches with the decoded polygon draw state. Static compilation
-- (MeshCompiler.compile + MapAssetCompiler) stays the default optimization;
-- a model uses the dynamic path only when it actually animates.
--
-- The materials here are the base contract the renderer needs (diffuse
-- tint, alpha class from polygon state, culling, the static texture-SRT
-- state and the texture-matrix convention); the MapAssetCompiler enriches
-- them with the bound textures, wrap/flip sampler state, pattern variants,
-- and animated colors. Pure domain module.

local FixedPoint = require("libs.math.src.FixedPoint")
local MeshCompiler = require("romdump.src.digest.MeshCompiler")
local DsMaterial = require("romdump.src.digest.nitro.DsMaterial")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")

local NsbmdDynamicModel = {}

-- One DS material register (a resolved 5-bit-per-channel color) as a
-- 0..255 per-channel record, the shape the runtime consumes.
local function channel(color)
  local r, g, b = FixedPoint.rgb555(color.rgb555)
  return { r = r, g = g, b = b }
end

-- Resolve one decoded material into the definition's base material record.
-- The four DS lighting registers (diffuse/ambient/specular/emission) are
-- carried per channel in `colors` -- the shader and the NSBMA sampler
-- distinguish them, so a uniform baseColor reconstruction would not match
-- the source material. `baseColor` stays as the alpha carrier and the
-- baseColor-fallback target for consumers of records without the block.
local function baseMaterial(mat, texMtxMode)
  local resolved = DsMaterial.resolve(mat, DsMaterial.HGSS_FIELD_DEFAULTS, DsMaterial.applyFieldPolicy(mat))
  local poly = DsPolygonAttr.decode(resolved.polyAttr)
  local diffuse = resolved.colors.diffuse
  local r, g, b = FixedPoint.rgb555(diffuse.rgb555)
  local material = {
    id = mat.index,
    name = mat.name,
    baseColor = {
      r = r,
      g = g,
      b = b,
      a = math.floor(poly.polygonAlpha * 255 / 31 + 0.5),
    },
    colors = {
      diffuse = channel(resolved.colors.diffuse),
      ambient = channel(resolved.colors.ambient),
      specular = channel(resolved.colors.specular),
      emission = channel(resolved.colors.emission),
    },
    alphaMode = poly.polygonAlpha < FixedPoint.RGB5_MAX and "blend" or "opaque",
    doubleSided = poly.cullMode ~= "back",
    polygonAlpha = poly.polygonAlpha,
    texMtxMode = texMtxMode or 0,
    texWidth = mat.origWidth,
    texHeight = mat.origHeight,
  }
  local srt = mat.textureSrt
  if srt then
    -- The static texture-SRT state in the shape the runtime evaluator
    -- consumes: "one" flags from the presence bits, values as authored.
    material.srt = {
      transS = srt.trans and srt.trans.s or 0,
      transT = srt.trans and srt.trans.t or 0,
      rot = srt.rot,
      scaleS = srt.scale and srt.scale.s or 0x1000,
      scaleT = srt.scale and srt.scale.t or 0x1000,
      transOne = srt.trans == nil,
      rotOne = srt.rot == nil,
      scaleOne = srt.scale == nil,
    }
    if srt.matrix then
      material.srtMatrix = srt.matrix
    end
  end
  return material
end

-- Compile a decoded Nsbmd model into the dynamic model descriptor.
-- Returns { program, meshes, materials }. The meshes carry their per-vertex
-- straddle provenance when a run was split at a mid-run matrix boundary (see
-- GxDisplayList dynamic mode); the straddle census over the corpus reads
-- MeshCompiler.compileDynamic directly. The transform program is compiled
-- once here and shared with the mesh compile.
function NsbmdDynamicModel.compile(model)
  assert(type(model) == "table" and model.sbc ~= nil, "NsbmdDynamicModel.compile requires a decoded Nsbmd model")
  local meshes, _, program = MeshCompiler.compileDynamic(model)
  -- UVs are texel units; normalize against the material's authored texture
  -- size, the base dimensions texture pattern variants are authored against
  -- (the animated layers keep the per-variant normalization).
  local materials = {}
  local texSize = {}
  for _, mat in ipairs(model.materials) do
    materials[mat.index] = baseMaterial(mat, model.info.texMtxMode)
    texSize[mat.index] = { width = mat.origWidth, height = mat.origHeight }
  end
  local materialList = {}
  for i = 0, #model.materials - 1 do
    materialList[#materialList + 1] = materials[i]
  end
  for _, mesh in ipairs(meshes) do
    local size = texSize[mesh.materialIndex]
    -- A material with no bound texture authors zero dimensions; leave its UVs
    -- as authored rather than dividing into NaN (the static path guards the
    -- same way).
    if size and size.width and size.height and size.width > 0 and size.height > 0 then
      for _, v in ipairs(mesh.batch.vertices) do
        v.u = v.u / size.width
        v.v = v.v / size.height
      end
    end
  end
  return {
    program = program,
    meshes = meshes,
    materials = materialList,
  }
end

return NsbmdDynamicModel
