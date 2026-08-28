-- NitroJointState: the composition step between a blended Nitro joint result
-- and the SRT record the SBC evaluator consumes.
--
-- Nsbca.sample / CompiledNsbcaSampler produce per-target results; several
-- attachments are combined per node by JointAnimBlend into one
-- NNSG3dAnmResult. That result still speaks Nitro fixed point: channels the
-- result leaves "from model" (the result's flag bits) must resolve against
-- the node's bind SRT, and the sampled channels are fx32 integers that must
-- become the float SRT the evaluator and NsbmdJointTransforms expect (one
-- unit = 0x1000, the same fixed-point step the model nodes are decoded
-- with).
--
-- The produced SRT record keeps the decoded-node shape (translation,
-- rotation, scale, inverseScale, transZero, rotZero, scaleOne,
-- matrixStackIndex) so a pose provider can hand it straight to
-- NsbmdSbcEvaluator; every component is emitted, since an animated channel
-- is never structurally absent. Pure domain module.

local JointAnimBlend = require("libs.engine.src.JointAnimBlend")

local NitroJointState = {}

-- One fixed-point unit: fx32 words are 1.M.12 (4096 per unit), the same
-- step the model nodes are decoded with.
local FX_UNIT = 4096

local F = JointAnimBlend.FROM_MODEL

local function fromModel(flags, bit)
  return math.floor(flags / bit) % 2 == 1
end

-- Result values are raw two's-complement fx32 words (the asm's wrapped
-- registers), so a negative value arrives as a large unsigned number.
local function wrap32(v)
  local p = v % 4294967296
  if p >= 2147483648 then
    p = p - 4294967296
  end
  return p
end

local function fxToFloat(v)
  return wrap32(v) / FX_UNIT
end

local function vecFromResult(v)
  return { x = fxToFloat(v[1]), y = fxToFloat(v[2]), z = fxToFloat(v[3]) }
end

local function rotFromResult(rot)
  local out = {}
  for i = 1, 9 do
    out[i] = fxToFloat(rot[i])
  end
  return out
end

-- The SRT record a pose provider hands to the SBC evaluator (the decoded
-- Nsbmd node record shape: translation/rotation/scale, the zero flags, the
-- inverse scale, and the matrix-stack slot the evaluator stores into).
---@class SrtRecord
---@field translation { x: number, y: number, z: number }
---@field rotation number[] -- 9 cells, column-major
---@field scale { x: number, y: number, z: number }
---@field inverseScale { x: number, y: number, z: number }|nil
---@field transZero boolean
---@field rotZero boolean
---@field scaleOne boolean
---@field matrixStackIndex integer

-- Compose the effective SRT record for a node:
--   result   a blended NNSG3dAnmResult (JointAnimBlend.blend output)
--   bindSrt  the node's bind SRT record (the program's node entry)
-- Channels the result leaves "from model" fall back to the bind values;
-- sampled channels convert from fx32. The zero flags are always false
-- (composition always emits every component), and matrixStackIndex is taken
-- from the bind record so the evaluator stores the world matrix in the
-- node's intended slot.
---@param result JointAnimResult
---@param bindSrt SrtRecord
---@return SrtRecord
function NitroJointState.srtFromBlend(result, bindSrt)
  assert(type(result) == "table" and result.flags ~= nil, "srtFromBlend requires a blended joint result")
  assert(type(bindSrt) == "table" and bindSrt.matrixStackIndex ~= nil, "srtFromBlend requires the node's bind SRT")

  local trans, rot, scale, inverseScale
  if fromModel(result.flags, F.trans) then
    trans = bindSrt.translation
  else
    trans = vecFromResult(result.trans)
  end

  if fromModel(result.flags, F.rot) then
    rot = bindSrt.rotation
  else
    rot = rotFromResult(result.rot)
  end

  if fromModel(result.flags, F.scale) then
    scale = bindSrt.scale
    inverseScale = bindSrt.inverseScale
  else
    scale = vecFromResult(result.scale)
    inverseScale = result.scaleEx and vecFromResult(result.scaleEx) or nil
  end

  return {
    translation = trans,
    rotation = rot,
    scale = scale,
    inverseScale = inverseScale,
    transZero = false,
    rotZero = false,
    scaleOne = false,
    matrixStackIndex = bindSrt.matrixStackIndex,
  }
end

return NitroJointState
