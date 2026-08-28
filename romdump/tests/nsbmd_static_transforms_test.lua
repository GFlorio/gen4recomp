-- Tests for NsbmdStaticTransforms: the bind-pose draw records the map
-- compiler bakes with. NsbmdStaticTransforms is the pose-driven evaluator
-- under the bind-pose provider; the bind-pose equivalence against the
-- dynamic mesh path is checked in nsbmd_dynamic_mesh_test.lua. Models are
-- built by NsbmdModelFixture.

local Assert = require("tests.support.Assert")
local NsbmdStaticTransforms = require("romdump.src.digest.NsbmdStaticTransforms")
local ModelFixture = require("tests.support.NsbmdModelFixture")
local Matrix4 = require("libs.math.src.Matrix4")
local NB = require("tests.support.NitroBuilder")

local function u32(v)
  return NB.u32(v)
end
local T = {}

local EPS = 1e-9

local function assertMatrixClose(actual, expected, msg)
  for i = 1, 16 do
    if math.abs(actual[i] - expected[i]) > EPS then
      error((msg or "matrix mismatch") .. " at index " .. i .. ": expected " .. expected[i] .. ", got " .. actual[i])
    end
  end
end

---@param m number[]
---@param x number
---@param y number
---@param z number
---@param ex number
---@param ey number
---@param ez number
---@param msg string?
local function assertMatrixAtPoint(m, x, y, z, ex, ey, ez, msg)
  local ax, ay, az = Matrix4.transformPoint(m, x, y, z)
  if math.abs(ax - ex) > EPS or math.abs(ay - ey) > EPS or math.abs(az - ez) > EPS then
    error(
      (msg or "transform mismatch")
        .. ": expected ("
        .. ex
        .. ","
        .. ey
        .. ","
        .. ez
        .. "), got ("
        .. ax
        .. ","
        .. ay
        .. ","
        .. az
        .. ")"
    )
  end
end

local identityNodeDictAndData = ModelFixture.identityNodeDictAndData
local transformedNodeData = ModelFixture.transformedNodeData
local decodeModel = ModelFixture.decodeModel
local decodeModelWithScalingRule = ModelFixture.decodeModelWithScalingRule
local nodemixModel = ModelFixture.nodemixModel
local evpEntry = ModelFixture.evpEntry

function T.identity_node_plus_posscale()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) -- NODEDESC node0 parent0 flags0
    .. string.char(0x02, 0, 1) -- NODE node0 visible
    .. string.char(0x0B) -- POSSCALE normal
    .. string.char(0x04, 0) -- MAT 0
    .. string.char(0x05, 0) -- SHP 0
    .. string.char(0x01) -- RET

  local model = decodeModel(nodeDict, nodeData, sbc, { posScale = 0x4000, invPosScale = 0x0400 })
  Assert.equal(model.info.posScale, 4)
  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 1)
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 4, 0, 0, "vertex scaled by posScale")
  assertMatrixAtPoint(draws[1].matrix, 0, 1, 0, 0, 4, 0, "vertex scaled by posScale")
end

function T.posscale_inverse_reverses_scale()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x0B) -- POSSCALE normal (posScale)
    .. string.char(0x05, 0) -- SHP 0
    .. string.char(0x2B) -- POSSCALE inverse (invPosScale)
    .. string.char(0x05, 0) -- SHP 0
    .. string.char(0x01)

  local model = decodeModel(nodeDict, nodeData, sbc, { posScale = 0x4000, invPosScale = 0x0400 })
  Assert.equal(model.info.posScale, 4)
  Assert.equal(model.info.invPosScale, 0.25)
  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 2)
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 4, 0, 0, "first draw scaled by posScale")
  assertMatrixClose(draws[2].matrix, Matrix4.identity(), "second draw restored to identity")
end

function T.node_translation_and_scale_in_matrix()
  local nodeData = transformedNodeData(2, 0, 0, 2, 1, 1)
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDataOffset = #nodeDict0
  local nodeDict = NB.dict({ { name = "root", data = u32(nodeDataOffset) } })

  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x02, 0, 1) .. string.char(0x05, 0) .. string.char(0x01)

  local model = decodeModel(nodeDict, nodeData, sbc)
  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 1)
  -- T * R * S: point (1,0,0) -> scale x2 -> translate +2 => (4,0,0)
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 4, 0, 0, "T*R*S reflected in draw matrix")
  assertMatrixAtPoint(draws[1].matrix, 0, 1, 0, 2, 1, 0, "T*R*S reflected in draw matrix")
end

function T.matrix_slot_restore()
  -- Two nodes, slot 0 and slot 1, each identity but translated differently.
  local node0Data = transformedNodeData(10, 0, 0, 1, 1, 1, 0)
  local node1Data = transformedNodeData(0, 20, 0, 1, 1, 1, 1)
  local combinedNodeData = node0Data .. node1Data

  local nodeDict0 = NB.dict({
    { name = "a", data = u32(0) },
    { name = "b", data = u32(#node0Data) },
  })
  local nodeDict = NB.dict({
    { name = "a", data = u32(#nodeDict0) },
    { name = "b", data = u32(#nodeDict0 + #node0Data) },
  })

  local sbc = string.char(0x06, 0, 0, 0) -- NODEDESC node0
    .. string.char(0x06, 1, 1, 0) -- NODEDESC node1 (parent = itself => root)
    .. string.char(0x03, 0) -- MTX restore slot 0
    .. string.char(0x05, 0) -- SHP 0
    .. string.char(0x03, 1) -- MTX restore slot 1
    .. string.char(0x05, 0) -- SHP 0
    .. string.char(0x01)

  local model = decodeModel(nodeDict, combinedNodeData, sbc, { numNode = 2 })

  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 2)
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 10, 0, 0, "first draw from slot 0")
  assertMatrixAtPoint(draws[2].matrix, 0, 0, 0, 0, 20, 0, "second draw from slot 1")
end

function T.stack_snapshot_is_independent()
  -- Slot 0 first holds node0's world matrix; after the first SHP we overwrite
  -- slot 0 with node1's matrix. The first draw's restoreStack must keep node0.
  local node0Data = transformedNodeData(5, 0, 0, 1, 1, 1, 0)
  local node1Data = transformedNodeData(0, 7, 0, 1, 1, 1, 0) -- same slot 0
  local combinedNodeData = node0Data .. node1Data

  local nodeDict0 = NB.dict({
    { name = "a", data = u32(0) },
    { name = "b", data = u32(#node0Data) },
  })
  local nodeDict = NB.dict({
    { name = "a", data = u32(#nodeDict0) },
    { name = "b", data = u32(#nodeDict0 + #node0Data) },
  })

  local sbc = string.char(0x06, 0, 0, 0) -- NODEDESC node0 -> stores in slot 0
    .. string.char(0x05, 0) -- SHP 0 (snapshots slot 0 = node0)
    .. string.char(0x06, 1, 1, 0) -- NODEDESC node1 -> overwrites slot 0
    .. string.char(0x05, 0) -- SHP 0 (snapshots slot 0 = node1)
    .. string.char(0x01)

  local model = decodeModel(nodeDict, combinedNodeData, sbc, { numNode = 2 })

  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 2)
  assertMatrixAtPoint(draws[1].restoreStack[0], 0, 0, 0, 5, 0, 0, "first snapshot kept node0 in slot 0")
  assertMatrixAtPoint(draws[2].restoreStack[0], 0, 0, 0, 0, 7, 0, "second snapshot has node1 in slot 0")
end

function T.invisible_node_skips_draw()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 0) -- NODE node0 invisible
    .. string.char(0x05, 0)
    .. string.char(0x01)

  local model = decodeModel(nodeDict, nodeData, sbc)
  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 0)
end

-- Si3D (rule 2) is unimplemented: no model in the target world uses it.
function T.rejects_si3d_scaling_rule()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x01)
  local model = decodeModelWithScalingRule(2, nodeDict, nodeData, sbc)
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(model)
  end)
  Assert.equal(err.code, "NSBMD_SBC_UNSUPPORTED_SCALING_RULE")
end

function T.accepts_the_maya_scaling_rule()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x04, 0) .. string.char(0x05, 0) .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(decodeModelWithScalingRule(1, nodeDict, nodeData, sbc))
  Assert.equal(#draws, 1)
  assertMatrixClose(draws[1].matrix, Matrix4.identity())
end

-- NODEDESC byte 3 carries the Maya scale-compensate bits, so a nonzero value
-- under the standard rule means the model was misread.
function T.rejects_nodedesc_flags_under_the_standard_rule()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0x01) .. string.char(0x01)
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(decodeModel(nodeDict, nodeData, sbc))
  end)
  Assert.equal(err.code, "NSBMD_JOINT_UNEXPECTED_NODEDESC_FLAGS")
end

-- A translated, non-uniformly scaled joint whose SBC then issues BB. The draw
-- must come out billboard-mode with the joint matrix as its base and an identity
-- local matrix, so the shape's vertices stay in billboard-local space.
local function billboardModel(extraAfterBB)
  local nodeData = transformedNodeData(2, 5, 0, 3, 1, 1)
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDict = NB.dict({ { name = "root", data = u32(#nodeDict0) } })
  local sbc = string.char(0x06, 0, 0, 0) -- NODEDESC node0
    .. string.char(0x02, 0, 1) -- NODE node0 visible
    .. string.char(0x07, 0) -- BB node0, option 0
    .. (extraAfterBB or "")
    .. string.char(0x04, 0) -- MAT 0
    .. string.char(0x05, 0) -- SHP 0
    .. string.char(0x01)
  return decodeModel(nodeDict, nodeData, sbc)
end

function T.billboard_reports_the_captured_joint_matrix()
  local draws = NsbmdStaticTransforms.evaluate(billboardModel())
  Assert.equal(#draws, 1)
  Assert.equal(draws[1].transformMode, "billboard")
  assertMatrixClose(draws[1].matrix, Matrix4.identity(), "billboard geometry stays in billboard-local space")
  -- Base = T(2,5,0) * S(3,1,1): the translation the runtime places the billboard
  -- at, and the per-axis scale it stretches by.
  assertMatrixAtPoint(draws[1].baseTransform, 0, 0, 0, 2, 5, 0, "base translation")
  assertMatrixAtPoint(draws[1].baseTransform, 1, 0, 0, 5, 5, 0, "base x scale")
end

function T.static_draws_report_static_mode()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x04, 0) .. string.char(0x05, 0) .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(decodeModel(nodeDict, nodeData, sbc))
  Assert.equal(draws[1].transformMode, "static")
  Assert.equal(draws[1].baseTransform, nil)
end

-- POSSCALE after BB acts on the installed billboard matrix, so it belongs to the
-- shape's local matrix and must not disturb the captured base.
function T.posscale_after_billboard_scales_the_local_matrix()
  local draws = NsbmdStaticTransforms.evaluate(billboardModel(string.char(0x0B)))
  Assert.equal(#draws, 1)
  Assert.equal(draws[1].transformMode, "billboard")
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 1, 0, 0, "posScale 1.0 leaves the local matrix")
  assertMatrixAtPoint(draws[1].baseTransform, 0, 0, 0, 2, 5, 0, "base translation unchanged")
end

-- MTX loads the position matrix outright, which ends the billboard.
function T.matrix_restore_after_billboard_returns_to_static()
  local nodeData = transformedNodeData(2, 0, 0, 1, 1, 1)
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDict = NB.dict({ { name = "root", data = u32(#nodeDict0) } })
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x07, 0) -- BB
    .. string.char(0x05, 0) -- SHP 0 (billboard)
    .. string.char(0x03, 0) -- MTX restore slot 0
    .. string.char(0x05, 0) -- SHP 0 (static again)
    .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(decodeModel(nodeDict, nodeData, sbc))
  Assert.equal(#draws, 2)
  Assert.equal(draws[1].transformMode, "billboard")
  Assert.equal(draws[2].transformMode, "static")
  Assert.equal(draws[2].baseTransform, nil)
  assertMatrixAtPoint(draws[2].matrix, 0, 0, 0, 2, 0, 0, "static draw back on the joint matrix")
end

-- Moving a billboard matrix through the matrix stack cannot be expressed by a
-- per-shape compiled transform; no BB in the target world uses the operands.
function T.rejects_billboard_with_matrix_slot_operands()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x27, 0, 1) -- BB with the store option, storing into slot 1
    .. string.char(0x01)
  local model = decodeModel(nodeDict, nodeData, sbc)
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(model)
  end)
  Assert.equal(err.code, "NSBMD_SBC_BILLBOARD_MATRIX_SLOT_UNSUPPORTED")
end

-- No model in the target world issues BBY, so its yaw-only semantics are
-- deliberately unimplemented rather than guessed at.
function T.rejects_y_billboard_command()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x08, 0) -- BBY
    .. string.char(0x01)
  local model = decodeModel(nodeDict, nodeData, sbc)
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(model)
  end)
  Assert.equal(err.code, "NSBMD_SBC_UNSUPPORTED_COMMAND")
end

-- ---- NODEMIX ----

-- NODEMIX: storeSlot 2, two terms of ratio 128 (half each) over slots 0 and 1.
local EVEN_BLEND = string.char(0x09, 2, 2, 0, 0, 128, 1, 1, 128)
  .. string.char(0x05, 0) -- SHP 0
  .. string.char(0x01)

function T.nodemix_blends_slots_through_the_inverse_bind_poses()
  local model = nodemixModel(EVEN_BLEND, evpEntry(0, 0, 0) .. evpEntry(0, 0, 0))
  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 1)
  -- Half of T(10,0,0) plus half of T(0,20,0).
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 5, 10, 0, "even blend of the two joint slots")
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 6, 10, 0, "identity bind poses leave the basis alone")
end

function T.nodemix_applies_the_inverse_bind_pose_before_the_slot()
  -- Joint 0's inverse bind pose pulls a vertex back by 4 on x before its slot
  -- matrix places it, so its term contributes 10 - 4 = 6.
  local model = nodemixModel(EVEN_BLEND, evpEntry(-4, 0, 0) .. evpEntry(0, 0, 0))
  local draws = NsbmdStaticTransforms.evaluate(model)
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 3, 10, 0, "inverse bind pose applied first")
end

function T.nodemix_stores_the_blend_in_its_destination_slot()
  local tail = string.char(0x09, 2, 2, 0, 0, 128, 1, 1, 128)
    .. string.char(0x03, 0) -- MTX restore slot 0 (moves off the blend)
    .. string.char(0x03, 2) -- MTX restore slot 2 (the stored blend)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(nodemixModel(tail, evpEntry(0, 0, 0) .. evpEntry(0, 0, 0)))
  Assert.equal(#draws, 1)
  Assert.equal(draws[1].transformMode, "static")
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 5, 10, 0, "slot 2 holds the blended matrix")
end

function T.nodemix_weights_follow_the_operand_ratios()
  -- 192/64 of 256: three quarters of joint 0, one quarter of joint 1.
  local tail = string.char(0x09, 2, 2, 0, 0, 192, 1, 1, 64) .. string.char(0x05, 0) .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(nodemixModel(tail, evpEntry(0, 0, 0) .. evpEntry(0, 0, 0)))
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 7.5, 5, 0, "ratio/256 weights")
end

-- The evaluator carries one matrix per slot, so a blended normal matrix only
-- follows from the blended position matrix while the bind poses are rigid.
function T.nodemix_rejects_a_non_rigid_bind_pose()
  local model = nodemixModel(EVEN_BLEND, evpEntry(0, 0, 0, 2) .. evpEntry(0, 0, 0))
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(model)
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODEMIX_NONRIGID_BIND_POSE")
end

function T.nodemix_without_an_evp_block_raises()
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(nodemixModel(EVEN_BLEND, nil))
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODEMIX_NO_EVP_MATRICES")
end

function T.nodemix_referencing_an_absent_joint_raises()
  -- Term two names joint 7, beyond the model's two nodes.
  local tail = string.char(0x09, 2, 2, 0, 0, 128, 1, 7, 128) .. string.char(0x05, 0) .. string.char(0x01)
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(nodemixModel(tail, evpEntry(0, 0, 0) .. evpEntry(0, 0, 0)))
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODEMIX_JOINT_NOT_FOUND")
end

-- A model with no NODEMIX still stores an ofsEvpMtx pointing past its data, so
-- the block must not be read speculatively.
function T.evp_matrices_are_only_decoded_for_a_model_that_blends()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x05, 0) .. string.char(0x01)
  local plain = decodeModel(nodeDict, nodeData, sbc)
  Assert.equal(plain.evpMatrices, nil)

  local blending = nodemixModel(EVEN_BLEND, evpEntry(0, 0, 0) .. evpEntry(0, 0, 0))
  Assert.notNil(blending.evpMatrices[0])
  Assert.notNil(blending.evpMatrices[1])
end

return { tests = T }
