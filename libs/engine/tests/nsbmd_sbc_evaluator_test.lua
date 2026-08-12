-- Tests for NsbmdSbcEvaluator: pose-driven SBC replay over a compiled
-- transform program. Programs here are hand-built data (no NSBMD bytes), so
-- the evaluator is exercised directly at the pose-provider boundary; the
-- bind-pose equivalence against the decoded-model static path lives in
-- romdump/tests/nsbmd_dynamic_mesh_test.lua.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local NsbmdSbcEvaluator = require("libs.engine.src.NsbmdSbcEvaluator")

local T = {}

local EPS = 1e-9

local function assertMatrixClose(actual, expected, msg)
  for i = 1, 16 do
    if math.abs(actual[i] - expected[i]) > EPS then
      error((msg or "matrix mismatch") .. " at index " .. i .. ": expected " .. expected[i] .. ", got " .. actual[i])
    end
  end
end

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

-- ---- fixtures ----

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- A bind SRT record: the decoded Nsbmd node shape the providers return.
local function srt(index, opts)
  opts = opts or {}
  return {
    index = index,
    matrixStackIndex = opts.matrixStackIndex or 0,
    translation = opts.translation or { x = 0, y = 0, z = 0 },
    rotation = opts.rotation or identity9(),
    scale = opts.scale or { x = 1, y = 1, z = 1 },
    inverseScale = opts.inverseScale,
    transZero = opts.transZero ~= nil and opts.transZero or opts.translation == nil,
    rotZero = opts.rotZero ~= nil and opts.rotZero or opts.rotation == nil,
    scaleOne = opts.scaleOne ~= nil and opts.scaleOne or opts.scale == nil,
  }
end

local function program(opts)
  opts = opts or {}
  return {
    name = opts.name or "test",
    scalingRule = opts.scalingRule or 0,
    posScale = opts.posScale or 1,
    invPosScale = opts.invPosScale or 1,
    nodes = opts.nodes or { srt(0) },
    commands = opts.commands or {},
    evpMatrices = opts.evpMatrices,
  }
end

-- The pose provider contract is nodeSRT only. The nodeVisible slot is kept
-- inert so tests can pin that a stray visibility hook is never consulted
-- (the SBC NODE command alone decides visibility).
local function provider(opts)
  opts = opts or {}
  return {
    nodeSRT = opts.nodeSRT or function()
      return nil
    end,
    nodeVisible = opts.nodeVisible,
  }
end

local function evaluate(p, prov)
  return NsbmdSbcEvaluator.evaluate(p, prov or provider()).draws
end

-- SBC command shortcuts (decoded entry shape, only the fields the evaluator
-- reads).
local function cmdNode(nodeIndex, visible)
  return { opcode = 0x02, nodeIndex = nodeIndex, visible = visible ~= false }
end
local function cmdMtx(slot)
  return { opcode = 0x03, matrixSlot = slot }
end
local function cmdMat(materialIndex)
  return { opcode = 0x04, materialIndex = materialIndex }
end
local function cmdShp(shapeIndex)
  return { opcode = 0x05, shapeIndex = shapeIndex }
end
local function cmdNodedesc(nodeIndex, parentIndex, flags, storeSlot, restoreSlot)
  local cmd = { opcode = 0x06, nodeIndex = nodeIndex, parentIndex = parentIndex, flags = flags or 0 }
  if storeSlot ~= nil then
    cmd.storeSlot = storeSlot
  end
  if restoreSlot ~= nil then
    cmd.restoreSlot = restoreSlot
  end
  return cmd
end
local function cmdBb(option)
  local cmd = { opcode = 0x07, option = option or 0, optionBits = (option or 0) * 0x20 }
  return cmd
end
local function cmdPoscale(inverse)
  return { opcode = 0x0B, inverse = inverse or false }
end

local function oneDraw(prefix)
  local cmds = {}
  for _, c in ipairs(prefix or {}) do
    cmds[#cmds + 1] = c
  end
  cmds[#cmds + 1] = cmdMat(0)
  cmds[#cmds + 1] = cmdShp(0)
  cmds[#cmds + 1] = { opcode = 0x01 } -- RET
  return cmds
end

-- ---- basic matrix semantics ----

function T.identity_node_plus_posscale()
  local p = program({
    posScale = 4,
    commands = oneDraw({
      cmdNodedesc(0, 0),
      cmdNode(0, true),
      cmdPoscale(false),
    }),
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#draws, 1)
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 4, 0, 0, "vertex scaled by posScale")
end

function T.posscale_inverse_reverses_scale()
  local p = program({
    posScale = 4,
    invPosScale = 0.25,
    commands = {
      cmdNodedesc(0, 0),
      cmdNode(0, true),
      cmdPoscale(false),
      cmdShp(0),
      cmdPoscale(true),
      cmdShp(0),
      cmdMat(0),
      { opcode = 0x01 },
    },
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#draws, 2)
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 4, 0, 0, "first draw scaled by posScale")
  assertMatrixClose(draws[2].matrix, Matrix4.identity(), "second draw restored to identity")
end

function T.node_translation_and_scale_in_matrix()
  local p = program({ commands = oneDraw({
    cmdNodedesc(0, 0),
    cmdNode(0, true),
  }) })
  p.nodes = { srt(0, { translation = { x = 2, y = 0, z = 0 }, scale = { x = 2, y = 1, z = 1 } }) }
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#draws, 1)
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 4, 0, 0, "T*R*S reflected in draw matrix")
  assertMatrixAtPoint(draws[1].matrix, 0, 1, 0, 2, 1, 0, "T*R*S reflected in draw matrix")
end

function T.matrix_slot_restore()
  local p = program({
    nodes = {
      srt(0, { matrixStackIndex = 0, translation = { x = 10, y = 0, z = 0 } }),
      srt(1, { matrixStackIndex = 1, translation = { x = 0, y = 20, z = 0 } }),
    },
    commands = {
      cmdNodedesc(0, 0),
      cmdNodedesc(1, 1),
      cmdMtx(0),
      cmdShp(0),
      cmdMtx(1),
      cmdShp(0),
      cmdMat(0),
      { opcode = 0x01 },
    },
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  Assert.equal(#draws, 2)
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 10, 0, 0, "first draw from slot 0")
  assertMatrixAtPoint(draws[2].matrix, 0, 0, 0, 0, 20, 0, "second draw from slot 1")
end

function T.stack_snapshot_is_independent()
  local p = program({
    nodes = {
      srt(0, { matrixStackIndex = 0, translation = { x = 5, y = 0, z = 0 } }),
      srt(1, { matrixStackIndex = 0, translation = { x = 0, y = 7, z = 0 } }),
    },
    commands = oneDraw({
      cmdNodedesc(0, 0),
      cmdShp(0),
      cmdNodedesc(1, 1),
      cmdShp(0),
    }),
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  assertMatrixAtPoint(draws[1].restoreStack[0], 0, 0, 0, 5, 0, 0, "first snapshot kept node0 in slot 0")
  assertMatrixAtPoint(draws[2].restoreStack[0], 0, 0, 0, 0, 7, 0, "second snapshot has node1 in slot 0")
end

-- The evaluation exposes the matrix-stack slots as of the end of the replay:
-- every NODEDESC stores its joint matrix into its node's stack slot, and the
-- stack is what the matrix-slot visualization reads.
function T.evaluation_reports_the_matrix_slot_stack()
  local p = program({
    nodes = {
      srt(0, { matrixStackIndex = 0, translation = { x = 10, y = 0, z = 0 } }),
      srt(1, { matrixStackIndex = 3, translation = { x = 0, y = 20, z = 0 } }),
    },
    commands = {
      cmdNodedesc(0, 0),
      cmdNodedesc(1, 1),
      { opcode = 0x01 },
    },
  })
  local result = NsbmdSbcEvaluator.evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  assertMatrixAtPoint(result.matrixSlots[0], 0, 0, 0, 10, 0, 0, "node 0 stored in slot 0")
  assertMatrixAtPoint(result.matrixSlots[3], 0, 0, 0, 0, 20, 0, "node 1 stored in slot 3")
  -- A later NODEDESC into the same slot overwrites it.
  local p2 = program({
    nodes = {
      srt(0, { matrixStackIndex = 0, translation = { x = 5, y = 0, z = 0 } }),
      srt(1, { matrixStackIndex = 0, translation = { x = 0, y = 7, z = 0 } }),
    },
    commands = {
      cmdNodedesc(0, 0),
      cmdNodedesc(1, 1),
      { opcode = 0x01 },
    },
  })
  local result2 = NsbmdSbcEvaluator.evaluate(
    p2,
    provider({
      nodeSRT = function(i)
        return p2.nodes[i + 1]
      end,
    })
  )
  assertMatrixAtPoint(result2.matrixSlots[0], 0, 0, 0, 0, 7, 0, "slot 0 holds the last writer")
end

function T.nodedesc_store_and_restore_option_slots()
  -- NODEDESC node0 with the store option into slot 3; a later NODEDESC
  -- restores slot 3 as its base.
  local p = program({
    nodes = {
      srt(0, { matrixStackIndex = 0, translation = { x = 1, y = 0, z = 0 } }),
      srt(1, { matrixStackIndex = 1, translation = { x = 2, y = 0, z = 0 } }),
    },
    commands = oneDraw({
      cmdNodedesc(0, 0, 0, 3),
      cmdNodedesc(1, 1, 0, nil, 3),
    }),
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  Assert.equal(#draws, 1)
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 3, 0, 0, "restored base (node0 at 1,0,0) times node1 local (2,0,0)")
end

-- ---- visibility ----

function T.invisible_node_skips_draw()
  local p = program({ commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, false) }) })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#draws, 0)
end

-- The pose-provider contract carries no visibility hook: the SBC NODE
-- command alone decides, so a provider-side nodeVisible is never consulted
-- (NSBVA support was deleted and no production provider ever supplied it).
function T.provider_node_visible_hook_is_not_consulted()
  local p = program({ commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, true) }) })
  local result = NsbmdSbcEvaluator.evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
      nodeVisible = function()
        return false
      end,
    })
  )
  Assert.equal(#result.draws, 1, "the SBC NODE command alone decides visibility")
  Assert.equal(result.nodeVisibility[0], true, "the NODE command alone decides visibility")
end

function T.evaluator_reports_node_matrices_and_visibility()
  local p = program({ commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, true) }) })
  local result = NsbmdSbcEvaluator.evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  assertMatrixClose(result.nodeMatrices[0], result.draws[1].matrix)
  Assert.equal(result.nodeVisibility[0], true)
end

-- ---- pose provider ----

function T.animated_srt_replaces_the_bind_srt()
  local p = program({ commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, true) }) })
  -- The provider animates the node's translation; the matrix must reflect it.
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return srt(0, { translation = { x = 30, y = 0, z = 0 } })
      end,
    })
  )
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 30, 0, 0, "animated translation applied")
end

function T.animated_rotation_and_scale_follow_the_provider()
  local p = program({ commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, true) }) })
  local rot = { 0, 0, -1, 0, 1, 0, 1, 0, 0 } -- rotY 90 degrees
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return srt(0, { rotation = rot, scale = { x = 3, y = 1, z = 1 } })
      end,
    })
  )
  -- rotate (1,0,0) -> (0,0,-1), then scale x3 -> (0,0,-3).
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 0, 0, -3, "rotation then scale in matrix")
end

function T.provider_nil_falls_back_to_the_bind_srt()
  local p = program({ commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, true) }) })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return nil
      end,
    })
  )
  assertMatrixClose(draws[1].matrix, Matrix4.identity(), "bind fallback is the program node")
end

function T.provider_missing_node_raises()
  local p = program({ nodes = {}, commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, true) }) })
  local prov = provider({
    nodeSRT = function()
      return nil
    end,
  })
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(p, prov)
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODE_NOT_FOUND")
end

-- ---- scaling rules ----

function T.accepts_the_maya_scaling_rule()
  local p = program({ scalingRule = 1, commands = oneDraw({ cmdNodedesc(0, 0), cmdNode(0, true) }) })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#draws, 1)
  assertMatrixClose(draws[1].matrix, Matrix4.identity())
end

function T.rejects_the_si3d_scaling_rule()
  local p = program({ scalingRule = 2, commands = oneDraw({ cmdNodedesc(0, 0) }) })
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function()
          return p.nodes[1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_UNSUPPORTED_SCALING_RULE")
end

function T.rejects_nodedesc_flags_under_the_standard_rule()
  local p = program({ commands = oneDraw({ cmdNodedesc(0, 0, 0x01) }) })
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function()
          return p.nodes[1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_JOINT_UNEXPECTED_NODEDESC_FLAGS")
end

function T.maya_parent_scale_compensation_uses_animated_inverse_scales()
  -- Parent publishes its inverse scale; child (flag 0x01 = MAYASSC_APPLY)
  -- compensates it. The provider animates both nodes' scales, so the
  -- compensated matrix must cancel the *animated* parent scale, not the bind.
  local parent = srt(0, { scale = { x = 2, y = 1, z = 1 }, inverseScale = { x = 0.5, y = 1, z = 1 } })
  local child = srt(1, { scale = { x = 1, y = 1, z = 1 }, inverseScale = { x = 1, y = 1, z = 1 } })
  local p = program({
    scalingRule = 1,
    nodes = { parent, child },
    commands = oneDraw({
      -- parent: flags 0x02 publishes its inverse scale for children
      cmdNodedesc(0, 0, 0x02),
      -- child: flags 0x01 applies the parent's inverse scale
      cmdNodedesc(1, 0, 0x01),
    }),
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(nodeIndex)
        -- Animated: parent scaled x4, inverse 0.25; child scaled x2.
        if nodeIndex == 0 then
          return srt(0, { scale = { x = 4, y = 1, z = 1 }, inverseScale = { x = 0.25, y = 1, z = 1 } })
        end
        return srt(1, { scale = { x = 2, y = 1, z = 1 }, inverseScale = { x = 0.5, y = 1, z = 1 } })
      end,
    })
  )
  -- Child cancels the animated parent scale: x axis 4 * 0.25 * 2 = 2.
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 2, 0, 0, "animated parent scale cancelled")
end

-- ---- billboards ----

local function billboardCommands(afterBB)
  local cmds = { cmdNodedesc(0, 0), cmdNode(0, true), cmdBb(0) }
  for _, c in ipairs(afterBB or {}) do
    cmds[#cmds + 1] = c
  end
  cmds[#cmds + 1] = cmdMat(0)
  cmds[#cmds + 1] = cmdShp(0)
  cmds[#cmds + 1] = { opcode = 0x01 }
  return cmds
end

function T.billboard_reports_the_captured_joint_matrix()
  local p = program({
    nodes = {
      srt(0, { translation = { x = 2, y = 5, z = 0 }, scale = { x = 3, y = 1, z = 1 } }),
    },
    commands = billboardCommands(),
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#draws, 1)
  Assert.equal(draws[1].transformMode, "billboard")
  assertMatrixClose(draws[1].matrix, Matrix4.identity(), "billboard geometry stays in billboard-local space")
  assertMatrixAtPoint(draws[1].baseTransform, 0, 0, 0, 2, 5, 0, "base translation")
  assertMatrixAtPoint(draws[1].baseTransform, 1, 0, 0, 5, 5, 0, "base x scale")
end

function T.billboard_base_tracks_the_animated_pose()
  local p = program({ commands = billboardCommands() })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return srt(0, { translation = { x = 9, y = 0, z = 0 } })
      end,
    })
  )
  Assert.equal(draws[1].transformMode, "billboard")
  assertMatrixAtPoint(draws[1].baseTransform, 0, 0, 0, 9, 0, 0, "animated base translation")
end

function T.posscale_after_billboard_scales_the_local_matrix()
  local p = program({ commands = billboardCommands({ cmdPoscale(false) }) })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(draws[1].transformMode, "billboard")
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 1, 0, 0, "posScale 1.0 leaves the local matrix")
end

function T.matrix_restore_after_billboard_returns_to_static()
  local p = program({
    nodes = {
      srt(0, { translation = { x = 2, y = 0, z = 0 } }),
    },
    commands = {
      cmdNodedesc(0, 0),
      cmdNode(0, true),
      cmdBb(0),
      cmdShp(0),
      cmdMtx(0),
      cmdShp(0),
      cmdMat(0),
      { opcode = 0x01 },
    },
  })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#draws, 2)
  Assert.equal(draws[1].transformMode, "billboard")
  Assert.equal(draws[2].transformMode, "static")
  Assert.equal(draws[2].baseTransform, nil)
  assertMatrixAtPoint(draws[2].matrix, 0, 0, 0, 2, 0, 0, "static draw back on the joint matrix")
end

function T.rejects_billboard_with_matrix_slot_operands()
  local p = program({ commands = billboardCommands() })
  p.commands[3] = { opcode = 0x07, option = 1, optionBits = 0x20 }
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function()
          return p.nodes[1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_BILLBOARD_MATRIX_SLOT_UNSUPPORTED")
end

function T.rejects_y_billboard_command()
  local p = program({ commands = { cmdNodedesc(0, 0), { opcode = 0x08 }, { opcode = 0x01 } } })
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function()
          return p.nodes[1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_UNSUPPORTED_COMMAND")
end

-- ---- NODEMIX ----

-- Decoded NNSG3dResEvpMtx entries are floats (FixedPoint.fx32 already
-- applied), matching the model's decoded evpMatrices.
local function evpEntry(tx, ty, tz, invNScale)
  invNScale = invNScale or 1
  return {
    invM = {
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      tx,
      ty,
      tz,
      1,
    },
    invN = {
      invNScale,
      0,
      0,
      0,
      0,
      invNScale,
      0,
      0,
      0,
      0,
      invNScale,
      0,
      0,
      0,
      0,
      1,
    },
  }
end

local function nodemixProgram(sbcTail, evpBlock)
  local cmds = {
    cmdNodedesc(0, 0),
    cmdNodedesc(1, 1),
  }
  for _, c in ipairs(sbcTail) do
    cmds[#cmds + 1] = c
  end
  return program({
    nodes = {
      srt(0, { matrixStackIndex = 0, translation = { x = 10, y = 0, z = 0 } }),
      srt(1, { matrixStackIndex = 1, translation = { x = 0, y = 20, z = 0 } }),
    },
    commands = cmds,
    evpMatrices = evpBlock,
  })
end

-- NODEMIX: storeSlot 2, two terms of ratio 128 (half each) over slots 0 and 1.
-- evp blocks are zero-based, like the decoded model's evpMatrices.
local function evpBlock()
  return { [0] = evpEntry(0, 0, 0), [1] = evpEntry(0, 0, 0) }
end

local EVEN_BLEND = {
  {
    opcode = 0x09,
    storeSlot = 2,
    terms = {
      { matrixSlot = 0, nodeIndex = 0, ratio = 128 },
      { matrixSlot = 1, nodeIndex = 1, ratio = 128 },
    },
  },
  cmdShp(0),
  { opcode = 0x01 },
}

function T.nodemix_blends_slots_through_the_inverse_bind_poses()
  local p = nodemixProgram(EVEN_BLEND, evpBlock())
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  Assert.equal(#draws, 1)
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 5, 10, 0, "even blend of the two joint slots")
  assertMatrixAtPoint(draws[1].matrix, 1, 0, 0, 6, 10, 0, "identity bind poses leave the basis alone")
end

function T.nodemix_applies_the_inverse_bind_pose_before_the_slot()
  local p = nodemixProgram(EVEN_BLEND, { [0] = evpEntry(-4, 0, 0), [1] = evpEntry(0, 0, 0) })
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 3, 10, 0, "inverse bind pose applied first")
end

function T.nodemix_stores_the_blend_in_its_destination_slot()
  local tail = {
    {
      opcode = 0x09,
      storeSlot = 2,
      terms = {
        { matrixSlot = 0, nodeIndex = 0, ratio = 128 },
        { matrixSlot = 1, nodeIndex = 1, ratio = 128 },
      },
    },
    cmdMtx(0),
    cmdMtx(2),
    cmdShp(0),
    { opcode = 0x01 },
  }
  local p = nodemixProgram(tail, evpBlock())
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  Assert.equal(#draws, 1)
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 5, 10, 0, "slot 2 holds the blended matrix")
end

function T.nodemix_weights_follow_the_operand_ratios()
  local tail = {
    {
      opcode = 0x09,
      storeSlot = 2,
      terms = {
        { matrixSlot = 0, nodeIndex = 0, ratio = 192 },
        { matrixSlot = 1, nodeIndex = 1, ratio = 64 },
      },
    },
    cmdShp(0),
    { opcode = 0x01 },
  }
  local p = nodemixProgram(tail, evpBlock())
  local draws = evaluate(
    p,
    provider({
      nodeSRT = function(i)
        return p.nodes[i + 1]
      end,
    })
  )
  assertMatrixAtPoint(draws[1].matrix, 0, 0, 0, 7.5, 5, 0, "ratio/256 weights")
end

function T.nodemix_rejects_a_non_rigid_bind_pose()
  local p = nodemixProgram(EVEN_BLEND, { [0] = evpEntry(0, 0, 0, 2), [1] = evpEntry(0, 0, 0) })
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function(i)
          return p.nodes[i + 1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODEMIX_NONRIGID_BIND_POSE")
end

function T.nodemix_without_an_evp_block_raises()
  local p = nodemixProgram(EVEN_BLEND, nil)
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function(i)
          return p.nodes[i + 1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODEMIX_NO_EVP_MATRICES")
end

function T.nodemix_referencing_an_absent_joint_raises()
  local tail = {
    {
      opcode = 0x09,
      storeSlot = 2,
      terms = {
        { matrixSlot = 0, nodeIndex = 0, ratio = 128 },
        { matrixSlot = 1, nodeIndex = 7, ratio = 128 },
      },
    },
    cmdShp(0),
    { opcode = 0x01 },
  }
  local p = nodemixProgram(tail, evpBlock())
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function(i)
          return p.nodes[i + 1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_NODEMIX_JOINT_NOT_FOUND")
end

-- ---- invalid programs ----

-- An opcode outside the handled set (0x00 NOP, 0x0C ENVMAP) raises
-- instead of falling through the chain silently.
function T.rejects_unknown_opcodes()
  for _, opcode in ipairs({ 0x00, 0x0C }) do
    local p = program({
      commands = { { opcode = opcode, name = "unknown", offset = 5 }, { opcode = 0x01 } },
    })
    local err = Assert.throws(function()
      NsbmdSbcEvaluator.evaluate(p, provider())
    end)
    Assert.equal(err.code, "NSBMD_SBC_UNKNOWN_OPCODE")
    Assert.equal(err.context.opcode, opcode)
  end
end

-- MTX restoring a matrix-stack slot no command ever wrote must raise with
-- the slot, command offset, and model in context -- a missing slot is a
-- malformed program, not an identity fallback.
function T.mtx_restore_of_an_unset_slot_raises()
  local mtx = cmdMtx(5)
  mtx.offset = 40
  local p = program({ commands = { mtx, { opcode = 0x01 } } })
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(p, provider())
  end)
  Assert.equal(err.code, "NSBMD_SBC_SLOT_NOT_FOUND")
  Assert.equal(err.context.slot, 5)
  Assert.equal(err.context.offset, 40)
  Assert.equal(err.context.model, "test")
end

function T.nodedesc_restore_of_an_unset_slot_raises()
  local cmd = cmdNodedesc(0, 0, 0, nil, 7)
  cmd.offset = 41
  local p = program({ commands = { cmd, { opcode = 0x01 } } })
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function()
          return p.nodes[1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_SLOT_NOT_FOUND")
  Assert.equal(err.context.slot, 7)
  Assert.equal(err.context.offset, 41)
  Assert.equal(err.context.model, "test")
end

function T.nodemix_term_referencing_an_unset_slot_raises()
  -- Nodes 0 and 1 write slots 0 and 1; the second term reads slot 9.
  local tail = {
    {
      opcode = 0x09,
      storeSlot = 2,
      offset = 42,
      terms = {
        { matrixSlot = 0, nodeIndex = 0, ratio = 128 },
        { matrixSlot = 9, nodeIndex = 1, ratio = 128 },
      },
    },
    cmdShp(0),
    { opcode = 0x01 },
  }
  local p = nodemixProgram(tail, evpBlock())
  local err = Assert.throws(function()
    NsbmdSbcEvaluator.evaluate(
      p,
      provider({
        nodeSRT = function(i)
          return p.nodes[i + 1]
        end,
      })
    )
  end)
  Assert.equal(err.code, "NSBMD_SBC_SLOT_NOT_FOUND")
  Assert.equal(err.context.slot, 9)
  Assert.equal(err.context.offset, 42)
  Assert.equal(err.context.model, "test")
end

-- PRJMAP selects projection-map texgen state only (NNSi_G3dFuncSbc_PRJMAP in
-- NitroSystem g3d/sbc.c): it reads and writes nothing on the position-matrix
-- stack, so the replay must leave the current matrix and the slots untouched.
-- Real HGSS data uses it (interior_build_models member 177 obj_sylph), so the
-- terminal unknown-opcode raise must not subsume it.
function T.prjmap_only_selects_texgen_state()
  local p = program({
    nodes = {
      srt(0, { translation = { x = 2, y = 0, z = 0 } }),
    },
    commands = oneDraw({
      cmdNodedesc(0, 0),
      cmdNode(0, true),
      { opcode = 0x0D, name = "PRJMAP", offset = 9 },
    }),
  })
  local result = NsbmdSbcEvaluator.evaluate(
    p,
    provider({
      nodeSRT = function()
        return p.nodes[1]
      end,
    })
  )
  Assert.equal(#result.draws, 1)
  assertMatrixAtPoint(result.draws[1].matrix, 0, 0, 0, 2, 0, 0, "PRJMAP leaves the position matrix untouched")
  assertMatrixAtPoint(result.matrixSlots[0], 0, 0, 0, 2, 0, 0, "the NODEDESC store survives unchanged")
  Assert.equal(result.matrixSlots[1], nil, "PRJMAP writes no matrix-stack slot")
end

return T
