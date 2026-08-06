-- Static evaluator for an NSBMD model's SBC draw stream.
--
-- NitroSystem's SBC commands drive the DS geometry engine's matrix stack:
-- NODEDESC computes joint matrices, POSSCALE folds the model header's posScale
-- in and out, MTX restores a stored slot, and SHP issues a shape draw. This
-- module replays those commands without LÖVE to produce, for every draw, the
-- position matrix and matrix-slot snapshot that the shape's display list must
-- inherit. See GBATEK "DS Video Geometry Commands" and NitroSystem g3d/sbc for
-- the command semantics; Nsbmd.lua already decodes the operands.
--
-- Joint matrices come from NsbmdJointTransforms, which reproduces the geometry-
-- engine command sequence the model's scaling rule emits; this module only
-- supplies the parent/stack context and the Maya inverse-scale cache.
--
-- BB cannot be baked, because the matrix it installs depends on the camera. It
-- is therefore evaluated in two halves: this module reports the position matrix
-- the command captured (`baseTransform`) and marks the draws it covers
-- `billboard`, and the engine's BillboardTransform rebuilds the real matrix each
-- frame. See NitroSystem g3d/src/sbc.c NNSi_G3dFuncSbc_BB: the command replaces
-- the position matrix with the accumulated translation and per-axis scale of the
-- matrix it captured, in view space, discarding its rotation.
--
-- NODEMIX blends matrix-stack slots through the joints' inverse bind poses. Only
-- the position sum is reproduced; see assertRigidBindPose for the checked
-- assumption that makes the normal sum follow from it.
--
-- Out of scope (fail loudly): BBY, external display lists (CALLDL), and the Si3D
-- scaling rule.
--
-- Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local NsbmdJointTransforms = require("romdump.src.digest.nitro.NsbmdJointTransforms")

local NsbmdStaticTransforms = {}

local function copyMatrix(m)
  return Matrix4.toArray(m)
end

local function copyRestoreStack(stack)
  local copy = {}
  for slot, matrix in pairs(stack) do
    copy[slot] = copyMatrix(matrix)
  end
  return copy
end

local function slotOrIdentity(slots, slot)
  local m = slots[slot]
  return m and copyMatrix(m) or Matrix4.identity()
end

-- The 4x3 part of a column-major matrix: the three basis columns plus the
-- translation. The implicit fourth row is (0,0,0,1), which NODEMIX never sums.
local AFFINE_INDICES = { 1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15 }
local LINEAR_INDICES = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

-- One fx32 step: the quantum the bind-pose matrices are stored in.
local FX32_STEP = 1 / 4096

-- NitroSystem accumulates two independent sums for NODEMIX (sbc.c
-- NNSi_G3dFuncSbc_NODEMIX):
--   sum.M = Σ wᵢ · (positionSlot[slotᵢ] × invM[jointᵢ])
--   sum.N = Σ wᵢ · (directionSlot[slotᵢ] × invN[jointᵢ])
-- This evaluator tracks position matrices per slot only, and GxDisplayList derives
-- each direction matrix as the linear part of its position matrix. Under that
-- contract sum.N comes out as the linear part of sum.M, which equals the SDK's
-- result exactly when invN is the linear part of invM -- true of a rigid bind
-- pose. So the property is checked per joint instead of being assumed: a model
-- with a non-rigid bind pose would need per-slot direction matrices threaded
-- through to the display-list decoder, and says so rather than blending wrong
-- normals.
local function assertRigidBindPose(evp, jointIndex, model)
  for _, i in ipairs(LINEAR_INDICES) do
    if math.abs(evp.invN[i] - evp.invM[i]) > FX32_STEP then
      Errors.raise("NSBMD_STATIC_NODEMIX_NONRIGID_BIND_POSE",
        "NODEMIX joint has an inverse normal matrix that is not the linear part of "
          .. "its inverse position matrix, so blended normals need separate direction slots",
        { jointIndex = jointIndex, model = model.name, element = i,
          invM = evp.invM[i], invN = evp.invN[i] })
    end
  end
end

-- The blended matrix a NODEMIX command installs and stores.
local function nodemixMatrix(model, cmd, matrixSlots)
  if not model.evpMatrices then
    Errors.raise("NSBMD_STATIC_NODEMIX_NO_EVP_MATRICES",
      "NODEMIX needs the model's inverse bind matrices, but it has no EvpMtx block",
      { model = model.name, offset = cmd.offset })
  end
  -- NNS_G3D_ASSERT(numMtx >= 2): fewer terms would be a plain MTX restore.
  assert(#cmd.terms >= 2, "NODEMIX must blend at least two matrices")

  local sum = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }
  for _, term in ipairs(cmd.terms) do
    local evp = model.evpMatrices[term.nodeIndex]
    if not evp then
      Errors.raise("NSBMD_STATIC_NODEMIX_JOINT_NOT_FOUND",
        "NODEMIX references joint index " .. tostring(term.nodeIndex),
        { jointIndex = term.nodeIndex, model = model.name, offset = cmd.offset })
    end
    assertRigidBindPose(evp, term.nodeIndex, model)
    -- The SDK restores the slot then multiplies invM into it, which in row-vector
    -- order applies invM to the vertex first.
    local m = Matrix4.multiply(slotOrIdentity(matrixSlots, term.matrixSlot), evp.invM)
    local weight = term.ratio / 256 -- the operand is `ratio << 4` in fx32
    for _, i in ipairs(AFFINE_INDICES) do sum[i] = sum[i] + weight * m[i] end
  end
  return sum
end

local SUPPORTED_SCALING_RULES = {
  [NsbmdJointTransforms.STANDARD] = true,
  [NsbmdJointTransforms.MAYA] = true,
}

local function assertSupportedModel(model)
  if not SUPPORTED_SCALING_RULES[model.info.scalingRule] then
    Errors.raise("NSBMD_STATIC_UNSUPPORTED_SCALING_RULE",
      "only the standard (0) and Maya (1) scaling rules are supported by static SBC evaluation",
      { scalingRule = model.info.scalingRule, model = model.name })
  end
end

-- Replay the SBC stream for `model` and return the ordered draw submissions.
-- Each submission is:
--   {
--     nodeIndex = <number>,
--     materialIndex = <number>,
--     shapeIndex = <number>,
--     materialReapplied = <boolean>,
--     matrix = <16-element column-major matrix>,
--     restoreStack = { [slot] = <matrix>, ... },
--     transformMode = "static" | "billboard",
--     baseTransform = <matrix>,  -- billboard draws only
--   }
-- For a billboard draw, `matrix` holds only what the stream accumulated after
-- the BB command (normally identity), so the shape's vertices stay in
-- billboard-local space; `baseTransform` is the matrix BB captured, from which
-- the runtime takes the translation and per-axis scale.
function NsbmdStaticTransforms.evaluate(model)
  assertSupportedModel(model)

  local currentMatrix = Matrix4.identity()
  local matrixSlots = {}
  local nodeMatrices = {}
  local nodeVisibility = {}
  local currentNode = 0
  local currentMaterial = 0
  local materialReapplied = true
  -- Written by joints flagged MAYASSC_PARENT and read by their children; the
  -- SDK keeps the equivalent state in NNS_G3dRSOnGlb.scaleCache for one walk.
  local mayaScaleCache = {}
  -- The position matrix a BB command captured, or nil while the current matrix is
  -- an ordinary joint matrix. Any command that loads the position matrix outright
  -- ends the billboard.
  local billboardBase = nil

  local draws = {}

  for _, cmd in ipairs(model.sbc.commands) do
    local op = cmd.opcode

    if op == 0x01 then -- RET
      break
    elseif op == 0x02 then -- NODE
      currentNode = cmd.nodeIndex
      nodeVisibility[cmd.nodeIndex] = cmd.visible
    elseif op == 0x03 then -- MTX
      currentMatrix = slotOrIdentity(matrixSlots, cmd.matrixSlot)
      billboardBase = nil
    elseif op == 0x04 then -- MAT
      currentMaterial = cmd.materialIndex
      materialReapplied = true
    elseif op == 0x05 then -- SHP
      if nodeVisibility[currentNode] ~= false then
        draws[#draws + 1] = {
          nodeIndex = currentNode,
          materialIndex = currentMaterial,
          shapeIndex = cmd.shapeIndex,
          materialReapplied = materialReapplied,
          matrix = copyMatrix(currentMatrix),
          restoreStack = copyRestoreStack(matrixSlots),
          transformMode = billboardBase and "billboard" or "static",
          baseTransform = billboardBase and copyMatrix(billboardBase) or nil,
        }
      end
      materialReapplied = false
    elseif op == 0x06 then -- NODEDESC
      local node = model.nodes[cmd.nodeIndex + 1]
      if not node then
        Errors.raise("NSBMD_STATIC_NODE_NOT_FOUND",
          "NODEDESC references node index " .. tostring(cmd.nodeIndex),
          { nodeIndex = cmd.nodeIndex, model = model.name })
      end

      local baseMatrix
      if cmd.restoreSlot ~= nil then
        baseMatrix = slotOrIdentity(matrixSlots, cmd.restoreSlot)
      elseif cmd.parentIndex ~= cmd.nodeIndex and nodeMatrices[cmd.parentIndex] then
        baseMatrix = copyMatrix(nodeMatrices[cmd.parentIndex])
      else
        baseMatrix = Matrix4.identity()
      end

      local localMatrix = NsbmdJointTransforms.localMatrix(
        model.info.scalingRule, node, cmd, mayaScaleCache)
      local world = Matrix4.multiply(baseMatrix, localMatrix)
      nodeMatrices[cmd.nodeIndex] = world
      matrixSlots[node.matrixStackIndex] = world
      if cmd.storeSlot ~= nil then
        matrixSlots[cmd.storeSlot] = world
      end
      currentMatrix = copyMatrix(world)
      currentNode = cmd.nodeIndex
      billboardBase = nil
    elseif op == 0x07 then -- BB
      -- The store/restore option operands would move a billboard matrix through
      -- the matrix stack, which the compiled per-shape contract cannot express.
      -- Every BB in the target world is option 0.
      if cmd.option ~= 0 then
        Errors.raise("NSBMD_STATIC_BILLBOARD_MATRIX_SLOT_UNSUPPORTED",
          "BB with store/restore option bits is not supported",
          { optionBits = cmd.optionBits, offset = cmd.offset, model = model.name })
      end
      billboardBase = copyMatrix(currentMatrix)
      currentMatrix = Matrix4.identity()
      currentNode = cmd.nodeIndex
    elseif op == 0x09 then -- NODEMIX
      local blended = nodemixMatrix(model, cmd, matrixSlots)
      matrixSlots[cmd.storeSlot] = blended
      currentMatrix = copyMatrix(blended)
      billboardBase = nil
    elseif op == 0x08 or op == 0x0A then
      -- BBY and CALLDL. CALLDL would submit geometry from a display list this
      -- evaluator never sees, so ignoring it would silently drop draws; no model
      -- in the target world issues either.
      Errors.raise("NSBMD_STATIC_UNSUPPORTED_SBC_COMMAND",
        cmd.name .. " is not supported by static SBC evaluation",
        { opcode = op, command = cmd.command, offset = cmd.offset, model = model.name })
    elseif op == 0x0B then -- POSSCALE
      local scale = cmd.inverse and model.info.invPosScale or model.info.posScale
      currentMatrix = Matrix4.multiply(currentMatrix, Matrix4.scale(scale, scale, scale))
    end
  end

  return draws
end

return NsbmdStaticTransforms
