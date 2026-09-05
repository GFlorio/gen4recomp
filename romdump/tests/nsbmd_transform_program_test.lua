-- Tests for NsbmdTransformProgram.compile: the digest-side projection of a
-- decoded NSBMD model into the serializable transform program the engine
-- evaluates. Compile-time validation owns the static program invariants that
-- never depend on the pose, so the per-frame evaluator does not re-check
-- them every animation frame.

local Assert = require("tests.support.Assert")
local NsbmdTransformProgram = require("romdump.src.digest.model.NsbmdTransformProgram")

local T = {}

-- A decoded-model-shaped fixture: only the fields compile reads. The SBC
-- stream carries one NODEMIX command referencing joint 0.
local function model(evpMatrices)
  return {
    name = "test",
    info = { scalingRule = 0, posScale = 1, invPosScale = 1 },
    nodes = {},
    sbc = {
      commands = {
        { opcode = 0x09, storeSlot = 2, terms = { { matrixSlot = 0, nodeIndex = 0, ratio = 256 } } },
      },
    },
    evpMatrices = evpMatrices,
  }
end

-- A decoded NNSG3dResEvpMtx entry (floats, FixedPoint.fx32 already applied).
-- invNScale = 2 makes the inverse normal matrix differ from the linear part
-- of the inverse position matrix: the non-rigid bind pose NODEMIX normals
-- depend on.
local function evpEntry(invNScale)
  local m = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  local n = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  n[1], n[6], n[11] = invNScale, invNScale, invNScale
  return { invM = m, invN = n }
end

-- NODEMIX blends through the joints' inverse bind poses; the direction
-- matrix of a draw is derived as the linear part of its position matrix, so
-- the sum reproduces the SDK's result only when invN is the linear part of
-- invM. That is a static property of the program, so it is rejected here at
-- compile time instead of every evaluation frame.
function T.rejects_a_non_rigid_bind_pose_on_nodemix_joints()
  local err = Assert.throws(function()
    NsbmdTransformProgram.compile(model({ [0] = evpEntry(2) }))
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODEMIX_NONRIGID_BIND_POSE")
  Assert.equal(err.context.jointIndex, 0)
end

-- The rigid program compiles; the check fires only for joints a NODEMIX
-- term actually references.
function T.rigid_bind_pose_compiles()
  local program = NsbmdTransformProgram.compile(model({ [0] = evpEntry(1) }))
  Assert.equal(program.evpMatrices[0].invN[1], 1)
end

return { tests = T }
