-- Nitro joint-SRT dispatch: turns one NODEDESC's decoded node record into the
-- local matrix the geometry engine would have accumulated for it.
--
-- NitroSystem selects a scaling rule per model (NNSG3dResMdlInfo.scalingRule)
-- and routes every joint through a matching GetJointScale/SendJointSRT pair.
-- Each SendJointSRT emits a sequence of geometry-engine matrix commands against
-- the current matrix, so the joint's local transform is the product of those
-- commands in emission order. This module reproduces that order rather than
-- guessing an equivalent multiplication:
--
--   standard (rule 0)  cgtool/basic.c  NNSi_G3dSendJointSRTBasic
--   maya     (rule 1)  cgtool/maya.c   NNSi_G3dSendJointSRTMaya / GetJointScaleMaya
--
-- Rule 2 (Si3D) is not implemented: no model in the target world uses it, and
-- its parent-chained scale cache has no asset to validate against.
--
-- Maya's "single scale compensate" makes a joint cancel its parent's scale. The
-- per-node inverse scales that requires live in a caller-owned cache, because
-- NNS_G3dRSOnGlb.scaleCache is written as the SBC stream is walked and read by
-- later joints. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")

local NsbmdJointTransforms = {}

NsbmdJointTransforms.STANDARD = 0
NsbmdJointTransforms.MAYA = 1
NsbmdJointTransforms.SI3D = 2

-- NNS_G3D_SBC_NODEDESC_FLAG_* (res_struct.h): byte 3 of a NODEDESC command.
local MAYASSC_APPLY = 0x01
local MAYASSC_PARENT = 0x02

local function bitSet(v, mask)
  return math.floor(v / mask) % 2 == 1
end

local function rotationMatrix(rot)
  return {
    rot[1],
    rot[2],
    rot[3],
    0,
    rot[4],
    rot[5],
    rot[6],
    0,
    rot[7],
    rot[8],
    rot[9],
    0,
    0,
    0,
    0,
    1,
  }
end

-- Compose an emitted command sequence. Each geometry-engine matrix command
-- post-multiplies the current matrix, so the joint's local matrix is the ops in
-- emission order, left to right.
local function compose(ops)
  local m = Matrix4.identity()
  for _, op in ipairs(ops) do
    m = Matrix4.multiply(m, op)
  end
  return m
end

local function translation(node)
  return Matrix4.translate(node.translation.x, node.translation.y, node.translation.z)
end

local function scaleOf(vec)
  return Matrix4.scale(vec.x, vec.y, vec.z)
end

-- NNSi_G3dSendJointSRTBasic: [MULT_4x3(rot|trans) | TRANS | MULT_3x3] then SCALE.
-- MULT_4x3 sends the rotation and translation as one 4x3, which is T * R.
local function standardOps(node)
  local ops = {}
  if not node.transZero then
    ops[#ops + 1] = translation(node)
  end
  if not node.rotZero then
    ops[#ops + 1] = rotationMatrix(node.rotation)
  end
  if not node.scaleOne then
    ops[#ops + 1] = scaleOf(node.scale)
  end
  return ops
end

-- NNSi_G3dSendJointSRTMaya. When the joint compensates its parent's scale, the
-- parent's inverse scale is applied after the translation and before the
-- rotation; otherwise the sequence is the standard one.
local function mayaOps(node, scaleEx0)
  local ops = {}
  if not node.transZero then
    ops[#ops + 1] = translation(node)
  end
  if scaleEx0 then
    ops[#ops + 1] = scaleOf(scaleEx0)
  end
  if not node.rotZero then
    ops[#ops + 1] = rotationMatrix(node.rotation)
  end
  if not node.scaleOne then
    ops[#ops + 1] = scaleOf(node.scale)
  end
  return ops
end

-- NNSi_G3dGetJointScaleMaya: publish this joint's inverse scale for children
-- that compensate it, and read the parent's when this joint compensates.
-- `cache` maps node index -> inverse scale, with `false` meaning "scale is one".
local function mayaScaleEx0(node, cmd, cache)
  if bitSet(cmd.flags, MAYASSC_PARENT) then
    cache[cmd.nodeIndex] = (not node.scaleOne) and node.inverseScale or false
  end
  if not bitSet(cmd.flags, MAYASSC_APPLY) then
    return nil
  end
  local parent = cache[cmd.parentIndex]
  -- A parent that never published a scale, or published scale one, contributes
  -- nothing: NNS_G3dRS->isScaleCacheOne starts set for every node.
  if not parent then
    return nil
  end
  return parent
end

-- Return the joint's local matrix for `model`'s scaling rule.
--   node   a decoded Nsbmd node (translation/rotation/scale, the SRT zero flags,
--          and inverseScale for the non-standard rules)
--   cmd    the NODEDESC command driving this joint (nodeIndex, parentIndex, flags)
--   cache  caller-owned Maya inverse-scale cache, mutated as joints are walked
function NsbmdJointTransforms.localMatrix(scalingRule, node, cmd, cache)
  if scalingRule == NsbmdJointTransforms.STANDARD then
    if cmd.flags ~= 0 then
      Errors.raise(
        "NSBMD_JOINT_UNEXPECTED_NODEDESC_FLAGS",
        string.format("NODEDESC flags 0x%02X are only defined for the Maya scaling rule", cmd.flags),
        { flags = cmd.flags, nodeIndex = cmd.nodeIndex, scalingRule = scalingRule }
      )
    end
    return compose(standardOps(node))
  end

  if scalingRule == NsbmdJointTransforms.MAYA then
    if not node.scaleOne and not node.inverseScale then
      Errors.raise(
        "NSBMD_JOINT_MISSING_INVERSE_SCALE",
        "a Maya joint with a scale must carry an inverse scale",
        { nodeIndex = cmd.nodeIndex, scalingRule = scalingRule }
      )
    end
    return compose(mayaOps(node, mayaScaleEx0(node, cmd, cache)))
  end

  Errors.raise(
    "NSBMD_JOINT_UNSUPPORTED_SCALING_RULE",
    "scaling rule " .. tostring(scalingRule) .. " is not implemented",
    { scalingRule = scalingRule, nodeIndex = cmd.nodeIndex }
  )
end

return NsbmdJointTransforms
