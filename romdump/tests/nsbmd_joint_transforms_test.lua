-- Scaling-rule dispatch tests. Expected matrices are written by hand from the
-- geometry-engine command sequence each SendJointSRT emits, not from this
-- module's own composition:
--
--   basic.c NNSi_G3dSendJointSRTBasic
--     [MTX_MULT_4x3(rot|trans) | MTX_TRANS | MTX_MULT_3x3] then MTX_SCALE(scale)
--   maya.c  NNSi_G3dSendJointSRTMaya
--     as above, but a scale-compensating joint emits MTX_TRANS(trans) and
--     MTX_SCALE(parent inverse scale) before the rotation.
--
-- Each command post-multiplies the current matrix, so the joint's local matrix
-- is that sequence applied left to right; the assertions check where the matrix
-- sends a probe point rather than comparing 16 raw cells.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local Joint = require("romdump.src.digest.nitro.NsbmdJointTransforms")

local T = {}

local IDENTITY_ROT = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
-- 90 degrees about Y in column-major: X -> -Z, Z -> X.
local ROT_Y90 = { 0, 0, -1, 0, 1, 0, 1, 0, 0 }

local function node(opts)
  local scale = opts.scale or { x = 1, y = 1, z = 1 }
  return {
    translation = opts.translation or { x = 0, y = 0, z = 0 },
    rotation = opts.rotation or IDENTITY_ROT,
    scale = scale,
    inverseScale = opts.inverseScale,
    transZero = opts.translation == nil,
    rotZero = opts.rotation == nil,
    scaleOne = opts.scale == nil,
  }
end

local function cmd(nodeIndex, parentIndex, flags)
  return { nodeIndex = nodeIndex, parentIndex = parentIndex, flags = flags or 0 }
end

local EPS = 1e-9

local function assertSends(m, from, expected, msg)
  local x, y, z = Matrix4.transformPoint(m, from[1], from[2], from[3])
  if math.abs(x - expected[1]) > EPS or math.abs(y - expected[2]) > EPS or math.abs(z - expected[3]) > EPS then
    error(
      string.format(
        "%s: expected (%s,%s,%s), got (%s,%s,%s)",
        msg or "transform mismatch",
        expected[1],
        expected[2],
        expected[3],
        x,
        y,
        z
      )
    )
  end
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected " .. code .. " to be raised")
  Assert.isTrue(Errors.is(err), "expected a structured Errors value, got " .. tostring(err))
  Assert.equal(err.code, code)
end

-- ---- standard (rule 0) ----

function T.standard_identity_joint_is_identity()
  local m = Joint.localMatrix(Joint.STANDARD, node({}), cmd(0, 0), {})
  Assert.deepEqual(m, Matrix4.identity())
end

-- TRANS(1,2,3) then SCALE(2,4,8): the point is scaled first, then translated.
function T.standard_composes_translation_then_scale()
  local m = Joint.localMatrix(
    Joint.STANDARD,
    node({ translation = { x = 1, y = 2, z = 3 }, scale = { x = 2, y = 4, z = 8 } }),
    cmd(0, 0),
    {}
  )
  assertSends(m, { 1, 1, 1 }, { 3, 6, 11 })
end

-- MULT_4x3 sends rotation and translation as one command, so the rotation is
-- applied before the translation and after the scale.
function T.standard_composes_translation_rotation_scale()
  local m = Joint.localMatrix(
    Joint.STANDARD,
    node({ translation = { x = 10, y = 0, z = 0 }, rotation = ROT_Y90, scale = { x = 2, y = 1, z = 1 } }),
    cmd(0, 0),
    {}
  )
  assertSends(m, { 1, 0, 0 }, { 10, 0, -2 })
end

function T.standard_rejects_maya_scale_compensate_flags()
  throwsCode("NSBMD_JOINT_UNEXPECTED_NODEDESC_FLAGS", function()
    Joint.localMatrix(Joint.STANDARD, node({}), cmd(1, 0, 0x01), {})
  end)
end

-- ---- maya (rule 1) ----

-- Without the scale-compensate bits Maya emits exactly the standard sequence.
function T.maya_without_compensation_matches_standard()
  local n = node({
    translation = { x = 1, y = 2, z = 3 },
    scale = { x = 2, y = 4, z = 8 },
    inverseScale = { x = 0.5, y = 0.25, z = 0.125 },
  })
  local maya = Joint.localMatrix(Joint.MAYA, n, cmd(0, 0), {})
  assertSends(maya, { 1, 1, 1 }, { 3, 6, 11 })
end

-- A MAYASSC_PARENT joint publishes its inverse scale; a MAYASSC_APPLY child then
-- emits TRANS then SCALE(parent inverse) before its own transform, cancelling
-- the parent's scale for the child's subtree.
function T.maya_child_compensates_a_non_uniform_parent_scale()
  local cache = {}
  Joint.localMatrix(
    Joint.MAYA,
    node({ scale = { x = 2, y = 4, z = 8 }, inverseScale = { x = 0.5, y = 0.25, z = 0.125 } }),
    cmd(0, 0, 0x02),
    cache
  )

  local child = Joint.localMatrix(Joint.MAYA, node({ translation = { x = 1, y = 0, z = 0 } }), cmd(1, 0, 0x01), cache)
  assertSends(child, { 1, 1, 1 }, { 1.5, 0.25, 0.125 })
end

function T.maya_child_compensates_a_uniform_parent_scale()
  local cache = {}
  Joint.localMatrix(
    Joint.MAYA,
    node({ scale = { x = 4, y = 4, z = 4 }, inverseScale = { x = 0.25, y = 0.25, z = 0.25 } }),
    cmd(0, 0, 0x02),
    cache
  )

  local child = Joint.localMatrix(Joint.MAYA, node({}), cmd(1, 0, 0x01), cache)
  assertSends(child, { 4, 8, 12 }, { 1, 2, 3 })
end

-- An unscaled parent publishes "scale is one", so the child compensates nothing
-- (the SDK's isScaleCacheOne bit short-circuits the scaleEx0 multiply).
function T.maya_child_of_an_unscaled_parent_is_unchanged()
  local cache = {}
  Joint.localMatrix(Joint.MAYA, node({}), cmd(0, 0, 0x02), cache)

  local child = Joint.localMatrix(Joint.MAYA, node({ translation = { x = 1, y = 0, z = 0 } }), cmd(1, 0, 0x01), cache)
  assertSends(child, { 1, 1, 1 }, { 2, 1, 1 })
end

-- The compensating scale lands after the child's translation, so the child's
-- own offset is not divided by the parent's scale.
function T.maya_translated_child_under_a_scaled_parent()
  local cache = {}
  Joint.localMatrix(
    Joint.MAYA,
    node({ scale = { x = 2, y = 2, z = 2 }, inverseScale = { x = 0.5, y = 0.5, z = 0.5 } }),
    cmd(0, 0, 0x02),
    cache
  )

  local child = Joint.localMatrix(
    Joint.MAYA,
    node({
      translation = { x = 3, y = 0, z = 0 },
      scale = { x = 2, y = 1, z = 1 },
      inverseScale = { x = 0.5, y = 1, z = 1 },
    }),
    cmd(1, 0, 0x01),
    cache
  )
  -- TRANS(3,0,0), SCALE(0.5,0.5,0.5), SCALE(2,1,1) applied right to left.
  assertSends(child, { 1, 2, 2 }, { 4, 1, 1 })
end

-- A joint that both publishes and compensates carries both bits.
function T.maya_joint_can_publish_and_compensate()
  local cache = {}
  Joint.localMatrix(
    Joint.MAYA,
    node({ scale = { x = 2, y = 2, z = 2 }, inverseScale = { x = 0.5, y = 0.5, z = 0.5 } }),
    cmd(0, 0, 0x02),
    cache
  )

  Joint.localMatrix(
    Joint.MAYA,
    node({ scale = { x = 4, y = 4, z = 4 }, inverseScale = { x = 0.25, y = 0.25, z = 0.25 } }),
    cmd(1, 0, 0x03),
    cache
  )

  local grandchild = Joint.localMatrix(Joint.MAYA, node({}), cmd(2, 1, 0x01), cache)
  assertSends(grandchild, { 4, 4, 4 }, { 1, 1, 1 })
end

function T.maya_requires_an_inverse_scale_on_a_scaled_joint()
  throwsCode("NSBMD_JOINT_MISSING_INVERSE_SCALE", function()
    Joint.localMatrix(Joint.MAYA, node({ scale = { x = 2, y = 2, z = 2 } }), cmd(0, 0), {})
  end)
end

-- ---- si3d (rule 2) ----

function T.si3d_is_not_implemented()
  throwsCode("NSBMD_JOINT_UNSUPPORTED_SCALING_RULE", function()
    Joint.localMatrix(Joint.SI3D, node({}), cmd(0, 0), {})
  end)
end

return T
