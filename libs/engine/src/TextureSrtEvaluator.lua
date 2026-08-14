-- TextureSrtEvaluator: the single composition of a material's normalized-UV
-- 3x3 texture matrix, shared by the dynamic-model evaluator and the terrain
-- animator so the two paths can never drift. Input is the generated base
-- material fields (texWidth/texHeight/texMtxMode and the optional static
-- `srt`) plus an optional sampled NSBTA state in the CompiledNsbtaSampler
-- result shape; a nil sample derives the static state from `material.srt`
-- exactly like the model evaluator, and a sample replaces it (the Nitro BTA
-- send replaces the material's matrix).
--
-- The convention is selected by texMtxMode; only Maya (mode 0) is
-- transcribed (NitroTexMatrix), so any other mode raises rather than
-- silently falling back. The matrix cells are built against the current
-- texture dimensions -- the terrain path always composes against the
-- material's own dimensions; the model evaluator passes variant-selected
-- dimensions when an NSBTP pattern switched textures:
--
--   uv' = M . (u, v, 1),  M = D(cur)^-1 . C(varDims) . D(base)
--
-- where D(x) reconstructs texel coordinates from the compile-time UV
-- normalization against the base texture size. Untextured materials (zero
-- dimensions) compose the identity matrix and carry no transform. The
-- serialized contract owns the SRT invariants (TextureMatrixState emits all
-- three "one" flags from source presence; MapAssetCache requires them), so
-- the evaluator never repairs an incomplete table -- an absent static srt is
-- the one shared identity state. The evaluator allocates only the fresh
-- matrix it returns; the material record and the sampled state are
-- read-only. Pure domain module.
local Errors = require("libs.errors.src.Errors")
local FixedPoint = require("libs.math.src.FixedPoint")
local NitroTexMatrix = require("libs.engine.src.NitroTexMatrix")

local TextureSrtEvaluator = {}

-- The texture-matrix conventions by material texMtxMode. Only Maya (mode 0)
-- is transcribed; Si3D (1), 3ds Max (2) and XSI (3) have no compiled
-- formulas and no real HGSS field asset uses them (census), so they raise
-- rather than silently falling back.
local MAYA_MODE = 0

-- Structured error code owned by this module.
TextureSrtEvaluator.ERROR_UNSUPPORTED_TEXMTX_MODE = "ANIM_MATERIAL_UNSUPPORTED_TEXMTX_MODE"

-- The one read-only identity static texture-SRT state (the shape a material
-- without a static srt implies): all components present as identity, with
-- every "one" flag set.
local IDENTITY_SRT = {
  transS = 0,
  transT = 0,
  rot = nil,
  scaleS = FixedPoint.FX32_SCALE,
  scaleT = FixedPoint.FX32_SCALE,
  transOne = true,
  rotOne = true,
  scaleOne = true,
}

-- Compose the six convention cells into the shader's normalized-UV 3x3
-- (column-major). `baseW/baseH` are the texture dimensions the mesh UVs
-- were normalized against at compile time; `curW/curH` the current
-- texture's dimensions.
--
-- The linear cells are 1.3.12 fixed point (scale 4096). The translation
-- cells live in the DS TEXCOORD domain instead: TEXCOORD coordinates are
-- 1.11.4 fixed point, the display-list decoder divides them by 16 to get
-- texels, and the convention translation folds carry the matching <<4
-- factors (NitroTexMatrix). They therefore divide by an extra 16 over the
-- linear cells: one fx32 translation unit (0x1000) is exactly one texture
-- width of normalized translation.
local function texMatrix(cells, baseW, baseH, curW, curH)
  local scale = FixedPoint.FX32_SCALE
  return {
    cells[1] * baseW / (scale * curW), -- m00: u * s
    cells[2] * baseW / (scale * curH), -- m10: v * s
    0,
    cells[3] * baseH / (scale * curW), -- m01: u * t
    cells[4] * baseH / (scale * curH), -- m11: v * t
    0,
    cells[5] / (scale * 16 * curW), -- m02: u translation (TEXCOORD)
    cells[6] / (scale * 16 * curH), -- m12: v translation (TEXCOORD)
    1,
  }
end

---@class SampledTexSrtState the CompiledNsbtaSampler result shape
---@field transS integer
---@field transT integer
---@field rot { sin: integer, cos: integer }|nil
---@field scaleS integer
---@field scaleT integer
---@field transOne boolean
---@field rotOne boolean
---@field scaleOne boolean

-- The normalized-UV 3x3 texMatrix of `material`. `srtOrNil` is the sampled
-- NSBTA state (CompiledNsbtaSampler result shape) or nil, in which case the
-- material's static `srt` is used directly (absent srt = the shared identity
-- state). The optional current dimensions default to the material's own; the
-- model evaluator passes pattern-selected variant dimensions when they
-- differ.
---@param material table generated material record with texWidth/texHeight/texMtxMode and optional srt
---@param srtOrNil SampledTexSrtState|nil
---@param curWidth integer|nil
---@param curHeight integer|nil
---@return number[]
function TextureSrtEvaluator.matrix(material, srtOrNil, curWidth, curHeight)
  assert(type(material) == "table", "TextureSrtEvaluator.matrix requires a material record")

  local srt = srtOrNil or material.srt or IDENTITY_SRT

  local mode = material.texMtxMode
  if mode ~= MAYA_MODE then
    Errors.raise(
      TextureSrtEvaluator.ERROR_UNSUPPORTED_TEXMTX_MODE,
      "material "
        .. tostring(material.name)
        .. " uses texture-matrix mode "
        .. tostring(mode)
        .. ", which has no compiled convention (only Maya mode 0 is supported)",
      { material = material.name, mode = mode }
    )
  end

  local baseW = material.texWidth
  local baseH = material.texHeight
  local curW = curWidth or material.texWidth
  local curH = curHeight or material.texHeight
  if baseW == 0 or baseH == 0 or curW == nil or curW == 0 or curH == nil or curH == 0 then
    -- Untextured materials carry no texture matrix.
    return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
  end

  local cells = NitroTexMatrix.maya({
    transS = srt.transS,
    transT = srt.transT,
    sin = srt.rot and srt.rot.sin or 0,
    cos = srt.rot and srt.rot.cos or 0,
    scaleS = srt.scaleS,
    scaleT = srt.scaleT,
    width = curW,
    height = curH,
    transOne = srt.transOne,
    rotOne = srt.rotOne,
    scaleOne = srt.scaleOne,
    ratioS = FixedPoint.FX32_SCALE,
    ratioT = FixedPoint.FX32_SCALE,
  })
  return texMatrix(cells, baseW, baseH, curW, curH)
end

return TextureSrtEvaluator
