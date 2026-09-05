-- TextureMatrixState: the digest-side conversion of one decoded DS material's
-- texture-matrix inputs into the shape the runtime evaluator consumes: the
-- model's texture-matrix mode, the authored texture dimensions, and the
-- normalized static texture-SRT state ("one" flags from the presence bits,
-- values as authored). Shared by the dynamic model base materials
-- (NsbmdDynamicModel) and the static terrain scene materials
-- (ModelAssetCompiler), so both emit exactly one conversion -- never a
-- second, slightly different copy. Pure domain module.

local TextureMatrixState = {}

---@param mat table<string, unknown> a decoded DS material record (Nsbmd material)
---@param texMtxMode integer the model's texture-matrix convention (Maya = 0)
---@return { texMtxMode: integer, texWidth: integer?, texHeight: integer?, srt?: table<string, unknown>, srtMatrix?: table<string, unknown> }
function TextureMatrixState.fromMaterial(mat, texMtxMode)
  assert(type(texMtxMode) == "number", "TextureMatrixState requires the model's texture-matrix convention")
  local state = {
    texMtxMode = texMtxMode,
    texWidth = mat.origWidth,
    texHeight = mat.origHeight,
  }
  local srt = mat.textureSrt
  if srt then
    state.srt = {
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
      state.srtMatrix = srt.matrix
    end
  end
  return state
end

return TextureMatrixState
