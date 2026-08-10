-- NsbmdSbcEvaluator: pose-driven replay of a Nitro model's SBC draw stream.
--
-- NitroSystem's SBC commands drive the DS geometry engine's matrix stack:
-- NODEDESC computes joint matrices, POSSCALE folds the model header's
-- posScale in and out, MTX restores a stored slot, and SHP issues a shape
-- draw. This evaluator replays those commands over a compiled transform
-- program (NsbmdTransformProgram on the digest side) with the node SRTs
-- supplied by a pose provider, so the same replay drives the static path
-- (bind pose) and the animated path (NSBCA poses). See GBATEK "DS Video
-- Geometry Commands" and NitroSystem g3d/sbc for the command semantics.
--
-- The pose provider contract:
--
--   poseProvider = {
--     nodeSRT(nodeIndex) -> SRT record | nil,
--         -- the effective node translation/rotation/scale/inverseScale
--         -- plus the transZero/rotZero/scaleOne flags; nil falls back to
--         -- the program's bind SRT (unaffected node)
--     nodeVisible(nodeIndex) -> boolean | nil,
--         -- visibility override (NSBVA-style hiding); nil lets the SBC
--         -- NODE command decide
--   }
--
-- The SRT record shape matches the decoded Nsbmd node record
-- (NsbmdJointTransforms composes it under the model's scaling rule), so a
-- bind-pose provider returning the program's own nodes reproduces the static
-- evaluation exactly -- the bind-pose equivalence invariant is checked in
-- romdump/tests/nsbmd_dynamic_mesh_test.lua, and NsbmdStaticTransforms is
-- that same evaluation under the bind-pose provider.
--
-- BB cannot be resolved here, because the matrix it installs depends on the
-- camera. It is therefore reported in two halves: the position matrix the
-- command captured (`baseTransform`, pose-dependent) and the billboard
-- marker; the runtime rebuilds the real matrix each frame
-- (BillboardTransform).
--
-- NODEMIX blends matrix-stack slots through the joints' inverse bind poses.
-- Only the position sum is reproduced; assertRigidBindPose enforces the
-- checked assumption that makes the normal sum follow from it.
--
-- Out of scope (fail loudly): BBY, external display lists (CALLDL), and the
-- Si3D scaling rule.
--
-- This module is pure domain: programs are decoded data, no ROM bytes are
-- read, and Matrix4/Errors are the only dependencies.

local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local NsbmdJointTransforms = require("libs.engine.src.NsbmdJointTransforms")
local PoseContract = require("libs.engine.src.PoseContract")

local NsbmdSbcEvaluator = {}

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
-- This evaluator tracks position matrices per slot only, and the direction
-- matrix of a draw is derived as the linear part of its position matrix.
-- Under that contract sum.N comes out as the linear part of sum.M, which
-- equals the SDK's result exactly when invN is the linear part of invM --
-- true of a rigid bind pose. So the property is checked per joint instead of
-- being assumed: a program with a non-rigid bind pose would need per-slot
-- direction matrices threaded through to the display-list decoder, and says
-- so rather than blending wrong normals.
local function assertRigidBindPose(program, jointIndex)
  local evp = program.evpMatrices[jointIndex]
  for _, i in ipairs(LINEAR_INDICES) do
    if math.abs(evp.invN[i] - evp.invM[i]) > FX32_STEP then
      Errors.raise(
        "NSBMD_SBC_NODEMIX_NONRIGID_BIND_POSE",
        "NODEMIX joint has an inverse normal matrix that is not the linear part of "
          .. "its inverse position matrix, so blended normals need separate direction slots",
        { jointIndex = jointIndex, model = program.name, element = i, invM = evp.invM[i], invN = evp.invN[i] }
      )
    end
  end
end

-- The blended matrix a NODEMIX command installs and stores.
local function nodemixMatrix(program, cmd, matrixSlots)
  if not program.evpMatrices then
    Errors.raise(
      "NSBMD_SBC_NODEMIX_NO_EVP_MATRICES",
      "NODEMIX needs the model's inverse bind matrices, but the program has no EvpMtx block",
      { model = program.name, offset = cmd.offset }
    )
  end
  -- NNS_G3D_ASSERT(numMtx >= 2): fewer terms would be a plain MTX restore.
  assert(#cmd.terms >= 2, "NODEMIX must blend at least two matrices")

  local sum = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }
  for _, term in ipairs(cmd.terms) do
    local evp = program.evpMatrices[term.nodeIndex]
    if not evp then
      Errors.raise(
        "NSBMD_SBC_NODEMIX_JOINT_NOT_FOUND",
        "NODEMIX references joint index " .. tostring(term.nodeIndex),
        { jointIndex = term.nodeIndex, model = program.name, offset = cmd.offset }
      )
    end
    assertRigidBindPose(program, term.nodeIndex)
    -- The SDK restores the slot then multiplies invM into it, which in row-vector
    -- order applies invM to the vertex first.
    local m = Matrix4.multiply(slotOrIdentity(matrixSlots, term.matrixSlot), evp.invM)
    local weight = term.ratio / 256 -- the operand is `ratio << 4` in fx32
    for _, i in ipairs(AFFINE_INDICES) do
      sum[i] = sum[i] + weight * m[i]
    end
  end
  return sum
end

local SUPPORTED_SCALING_RULES = {
  [NsbmdJointTransforms.STANDARD] = true,
  [NsbmdJointTransforms.MAYA] = true,
}

-- The draw record shape evaluate produces (see the function doc for the
-- billboard split).
---@class SbcDraw
---@field nodeIndex integer
---@field materialIndex integer
---@field shapeIndex integer
---@field materialReapplied boolean
---@field matrix number[] -- 16-element column-major matrix (program units)
---@field restoreStack { [integer]: number[] }
---@field transformMode TransformMode
---@field baseTransform number[]|nil -- billboard draws only

---@class SbcEvaluation
---@field draws SbcDraw[]
---@field nodeMatrices { [integer]: number[] } -- NODEDESC results
---@field nodeVisibility { [integer]: boolean } -- effective NODE visibility
---@field matrixSlots { [integer]: number[] } -- the matrix-stack slots as of the
--  end of the replay, [slot] = column-major matrix (program units)

-- Replay the SBC stream of `program` with `poseProvider` and return the
-- ordered draw submissions plus the effective node state.
--
-- For a billboard draw, `matrix` holds only what the stream accumulated
-- after the BB command (normally identity), so the shape's vertices stay in
-- billboard-local space; `baseTransform` is the matrix BB captured, from
-- which the runtime takes the translation and per-axis scale.
---@return SbcEvaluation
function NsbmdSbcEvaluator.evaluate(program, poseProvider)
  assert(
    type(program) == "table" and program.commands ~= nil,
    "NsbmdSbcEvaluator.evaluate requires a transform program"
  )
  assert(
    type(poseProvider) == "table" and poseProvider.nodeSRT ~= nil,
    "NsbmdSbcEvaluator.evaluate requires a pose provider with nodeSRT"
  )

  local scalingRule = program.scalingRule
  if not SUPPORTED_SCALING_RULES[scalingRule] then
    Errors.raise(
      "NSBMD_SBC_UNSUPPORTED_SCALING_RULE",
      "only the standard (0) and Maya (1) scaling rules are supported by SBC evaluation",
      { scalingRule = scalingRule, model = program.name }
    )
  end

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

  for _, cmd in ipairs(program.commands) do
    local op = cmd.opcode

    if op == 0x01 then -- RET
      break
    elseif op == 0x02 then -- NODE
      currentNode = cmd.nodeIndex
      local override = poseProvider.nodeVisible and poseProvider.nodeVisible(cmd.nodeIndex)
      nodeVisibility[cmd.nodeIndex] = cmd.visible and override ~= false
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
          transformMode = billboardBase and PoseContract.BILLBOARD or PoseContract.STATIC,
          baseTransform = billboardBase and copyMatrix(billboardBase) or nil,
        }
      end
      materialReapplied = false
    elseif op == 0x06 then -- NODEDESC
      local srt = poseProvider.nodeSRT(cmd.nodeIndex) or program.nodes[cmd.nodeIndex + 1]
      if not srt then
        Errors.raise(
          "NSBMD_SBC_NODE_NOT_FOUND",
          "NODEDESC references node index " .. tostring(cmd.nodeIndex),
          { nodeIndex = cmd.nodeIndex, model = program.name }
        )
      end

      local baseMatrix
      if cmd.restoreSlot ~= nil then
        baseMatrix = slotOrIdentity(matrixSlots, cmd.restoreSlot)
      elseif cmd.parentIndex ~= cmd.nodeIndex and nodeMatrices[cmd.parentIndex] then
        baseMatrix = copyMatrix(nodeMatrices[cmd.parentIndex])
      else
        baseMatrix = Matrix4.identity()
      end

      local localMatrix = NsbmdJointTransforms.localMatrix(scalingRule, srt, cmd, mayaScaleCache)
      local world = Matrix4.multiply(baseMatrix, localMatrix)
      nodeMatrices[cmd.nodeIndex] = world
      matrixSlots[srt.matrixStackIndex] = world
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
        Errors.raise(
          "NSBMD_SBC_BILLBOARD_MATRIX_SLOT_UNSUPPORTED",
          "BB with store/restore option bits is not supported",
          { optionBits = cmd.optionBits, offset = cmd.offset, model = program.name }
        )
      end
      billboardBase = copyMatrix(currentMatrix)
      currentMatrix = Matrix4.identity()
      currentNode = cmd.nodeIndex
    elseif op == 0x09 then -- NODEMIX
      local blended = nodemixMatrix(program, cmd, matrixSlots)
      matrixSlots[cmd.storeSlot] = blended
      currentMatrix = copyMatrix(blended)
      billboardBase = nil
    elseif op == 0x08 or op == 0x0A then
      -- BBY and CALLDL. CALLDL would submit geometry from a display list this
      -- evaluator never sees, so ignoring it would silently drop draws; no model
      -- in the target world issues either.
      Errors.raise(
        "NSBMD_SBC_UNSUPPORTED_COMMAND",
        (cmd.name or "SBC command") .. " is not supported by SBC evaluation",
        { opcode = op, command = cmd.command, offset = cmd.offset, model = program.name }
      )
    elseif op == 0x0B then -- POSSCALE
      local scale = cmd.inverse and program.invPosScale or program.posScale
      currentMatrix = Matrix4.multiply(currentMatrix, Matrix4.scale(scale, scale, scale))
    end
  end

  return {
    draws = draws,
    nodeMatrices = nodeMatrices,
    nodeVisibility = nodeVisibility,
    matrixSlots = copyRestoreStack(matrixSlots),
  }
end

return NsbmdSbcEvaluator
