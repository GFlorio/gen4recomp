-- Tests for NsbmdStaticTransforms: replaying an NSBMD SBC stream to produce
-- per-draw position matrices and matrix-slot snapshots.

local Assert = require("tests.support.Assert")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local NsbmdStaticTransforms = require("romdump.src.digest.NsbmdStaticTransforms")
local NB = require("tests.support.NitroBuilder")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function u32(v) return NB.u32(v) end
local function u16(v) return NB.u16(v) end
local function u8(v) return NB.u8(v) end

local EPS = 1e-9

local function assertMatrixClose(actual, expected, msg)
  for i = 1, 16 do
    if math.abs(actual[i] - expected[i]) > EPS then
      error((msg or "matrix mismatch") .. " at index " .. i .. ": expected " ..
        expected[i] .. ", got " .. actual[i])
    end
  end
end

local function assertMatrixAtPoint(m, x, y, z, ex, ey, ez, msg)
  local ax, ay, az = Matrix4.transformPoint(m, x, y, z)
  if math.abs(ax - ex) > EPS or math.abs(ay - ey) > EPS or math.abs(az - ez) > EPS then
    error((msg or "transform mismatch") .. ": expected (" ..
      ex .. "," .. ey .. "," .. ez .. "), got (" .. ax .. "," .. ay .. "," .. az .. ")")
  end
end

-- One-triangle display list (BEGIN triangles, 3x VTX_16, END).
local function triangleDL()
  local function vtx16(x, y, z)
    local function raw(c) return math.floor(c * 4096) % 0x10000 end
    return u32(raw(x) + raw(y) * 0x10000) .. u32(raw(z))
  end
  return string.char(0x40, 0x23, 0x23, 0x23) .. u32(0)
    .. vtx16(0, 0, 0) .. vtx16(1, 0, 0) .. vtx16(0, 1, 0)
    .. string.char(0x41, 0, 0, 0)
end

local function buildMaterialBlock()
  local diffAmb = 0x1F + 0x8000 + 0x03E0 * 0x10000
  local specEmi = 0x7C00 + 0x3DEF * 0x10000
  local matData = u16(0) .. u16(0x2C) .. u32(diffAmb) .. u32(specEmi)
    .. u32(0x001F00C1) .. u32(0xFFFFFFFF)
    .. u32(0x30000) .. u32(0xFFFFFFFF) .. u16(0) .. u16(0x140)
    .. u16(8) .. u16(16) .. u32(0x1000) .. u32(0x1000)

  local texToMatEntry = function(ofsList) return u16(ofsList) .. string.char(1, 0) end

  local matDict0 = NB.dict({ { name = "mat0", data = u32(0) } })
  local texDict0 = NB.dict({ { name = "tex0", data = texToMatEntry(0) } })
  local pltDict0 = NB.dict({ { name = "pal0", data = texToMatEntry(0) } })
  local listBase = 4 + #matDict0 + #texDict0 + #pltDict0 + 2

  local texDict = NB.dict({ { name = "tex0", data = texToMatEntry(listBase) } })
  local pltDict = NB.dict({ { name = "pal0", data = texToMatEntry(listBase + 1) } })
  local ofsMatData = 4 + #matDict0 + #texDict + #pltDict + 2
  local matDict = NB.dict({ { name = "mat0", data = u16(ofsMatData) .. u16(0) } })

  return u16(4 + #matDict) .. u16(4 + #matDict + #texDict)
    .. matDict .. texDict .. pltDict .. string.char(0, 0)
    .. matData
end

local function buildShapeBlock(dl)
  local shpDict0 = NB.dict({ { name = "shp0", data = u32(0) } })
  local shapeDataOffset = #shpDict0
  local shapeData = u32(0) .. u32(0) .. u32(16) .. u32(#dl)
  local shpDict = NB.dict({ { name = "shp0", data = u32(shapeDataOffset) } })
  return shpDict .. shapeData .. dl
end

local function buildInfo(numNode, numMat, numShp, posScale, invPosScale)
  local fields = {}
  fields[#fields + 1] = u8(0)   -- sbcType
  fields[#fields + 1] = u8(0)   -- scalingRule
  fields[#fields + 1] = u8(0)   -- texMtxMode
  fields[#fields + 1] = u8(numNode)
  fields[#fields + 1] = u8(numMat)
  fields[#fields + 1] = u8(numShp)
  fields[#fields + 1] = u8(0)   -- firstUnusedMtxStackID
  fields[#fields + 1] = u8(0)   -- dummy
  fields[#fields + 1] = u32(posScale or 0x1000)
  fields[#fields + 1] = u32(invPosScale or 0x1000)
  fields[#fields + 1] = u16(3)  -- numVertex
  fields[#fields + 1] = u16(1)  -- numPolygon
  fields[#fields + 1] = u16(1)  -- numTriangle
  fields[#fields + 1] = u16(0)  -- numQuad
  for i = 1, 6 do fields[#fields + 1] = u16(0) end -- box x,y,z,w,h,d
  fields[#fields + 1] = u32(0x4000) -- boxPosScale
  fields[#fields + 1] = u32(0x0800) -- boxInvPosScale
  return table.concat(fields)
end

local function buildModelDict(model)
  local modelDict0 = NB.dict({ { name = "m0", data = u32(0) } })
  local modelOffset = 8 + #modelDict0
  local modelDict = NB.dict({ { name = "m0", data = u32(modelOffset) } })
  return modelDict .. model
end

-- Model layout: header(0x14) + info(0x2C) + nodeDict + nodeData + sbc + matBlock + shpBlock.
local function buildModel(nodeDict, nodeData, sbc, posScale, invPosScale)
  local numNode = 1 -- default; caller must match nodeDict
  local matBlock = buildMaterialBlock()
  local shpBlock = buildShapeBlock(triangleDL())
  local info = buildInfo(numNode, 1, 1, posScale, invPosScale)

  local ofsSbc = 0x40 + #nodeDict + #nodeData
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock

  local body = string.rep("\0", 0x14) .. info .. nodeDict .. nodeData .. sbc .. matBlock .. shpBlock
  local model = u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(0)
    .. body:sub(0x15)
  return model
end

local function decodeModel(nodeDict, nodeData, sbc, posScale, invPosScale)
  local model = buildModel(nodeDict, nodeData, sbc, posScale, invPosScale)
  local file = NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(model) } })
  local m = assert(Nsbmd.decode(file))
  return m.models[1]
end

-- The same model with NNSG3dResMdlInfo.scalingRule overwritten. The info block
-- starts at model offset 0x14 and scalingRule is its second byte.
local function decodeModelWithScalingRule(rule, nodeDict, nodeData, sbc)
  local model = buildModel(nodeDict, nodeData, sbc, 0x1000, 0x1000)
  model = model:sub(1, 0x15) .. string.char(rule) .. model:sub(0x17)
  local file = NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(model) } })
  return assert(Nsbmd.decode(file)).models[1]
end

local function identityNodeDictAndData(slot)
  slot = slot or 0
  -- flags = TRANS_ZERO | ROT_ZERO | SCALE_ONE; matrix-stack index in bits 11-15.
  local flags = 0x0007 + slot * 2048
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDataOffset = #nodeDict0
  local nodeDict = NB.dict({ { name = "root", data = u32(nodeDataOffset) } })
  local nodeData = u16(flags) .. u16(0)
  return nodeDict, nodeData
end

-- Node with translation (tx,ty,tz), identity rotation, scale (sx,sy,sz).
local function transformedNodeData(tx, ty, tz, sx, sy, sz, slot)
  slot = slot or 0
  local flags = slot * 2048 -- no zero flags: translation, rotation, scale all present
  local function fx32(v) return u32(math.floor(v * 4096)) end
  local data = u16(flags) .. u16(0x1000) -- _00 = 1.0 (a[1])
    .. fx32(tx) .. fx32(ty) .. fx32(tz)
    -- Remaining 8 components of the 3x3 rotation matrix (a[2]..a[9]), identity.
    .. u16(0) .. u16(0) .. u16(0)
    .. u16(0x1000) .. u16(0) .. u16(0)
    .. u16(0) .. u16(0x1000)
    .. fx32(sx) .. fx32(sy) .. fx32(sz)
  return data
end

function T.identity_node_plus_posscale()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)   -- NODEDESC node0 parent0 flags0
    .. string.char(0x02, 0, 1)             -- NODE node0 visible
    .. string.char(0x0B)                   -- POSSCALE normal
    .. string.char(0x04, 0)                -- MAT 0
    .. string.char(0x05, 0)                -- SHP 0
    .. string.char(0x01)                   -- RET

  local model = decodeModel(nodeDict, nodeData, sbc, 0x4000, 0x0400)
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
    .. string.char(0x0B)                   -- POSSCALE normal (posScale)
    .. string.char(0x05, 0)                -- SHP 0
    .. string.char(0x2B)                   -- POSSCALE inverse (invPosScale)
    .. string.char(0x05, 0)                -- SHP 0
    .. string.char(0x01)

  local model = decodeModel(nodeDict, nodeData, sbc, 0x4000, 0x0400)
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

  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x05, 0)
    .. string.char(0x01)

  local model = decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000)
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
    .. string.char(0x06, 1, 1, 0)        -- NODEDESC node1 (parent = itself => root)
    .. string.char(0x03, 0)              -- MTX restore slot 0
    .. string.char(0x05, 0)              -- SHP 0
    .. string.char(0x03, 1)              -- MTX restore slot 1
    .. string.char(0x05, 0)              -- SHP 0
    .. string.char(0x01)

  -- Must tell buildInfo there are two nodes.
  local matBlock = buildMaterialBlock()
  local shpBlock = buildShapeBlock(triangleDL())
  local info = buildInfo(2, 1, 1, 0x1000, 0x1000)
  local ofsSbc = 0x40 + #nodeDict + #combinedNodeData
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock
  local body = string.rep("\0", 0x14) .. info .. nodeDict .. combinedNodeData .. sbc .. matBlock .. shpBlock
  local modelBytes = u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(0)
    .. body:sub(0x15)
  local file = NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(modelBytes) } })
  local m = assert(Nsbmd.decode(file))
  local model = m.models[1]

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
    .. string.char(0x05, 0)              -- SHP 0 (snapshots slot 0 = node0)
    .. string.char(0x06, 1, 1, 0)        -- NODEDESC node1 -> overwrites slot 0
    .. string.char(0x05, 0)              -- SHP 0 (snapshots slot 0 = node1)
    .. string.char(0x01)

  local matBlock = buildMaterialBlock()
  local shpBlock = buildShapeBlock(triangleDL())
  local info = buildInfo(2, 1, 1, 0x1000, 0x1000)
  local ofsSbc = 0x40 + #nodeDict + #combinedNodeData
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock
  local body = string.rep("\0", 0x14) .. info .. nodeDict .. combinedNodeData .. sbc .. matBlock .. shpBlock
  local modelBytes = u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(0)
    .. body:sub(0x15)
  local file = NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(modelBytes) } })
  local m = assert(Nsbmd.decode(file))
  local model = m.models[1]

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

  local model = decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000)
  local draws = NsbmdStaticTransforms.evaluate(model)
  Assert.equal(#draws, 0)
end

-- Si3D (rule 2) is unimplemented: no model in the target world uses it.
function T.rejects_si3d_scaling_rule()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x01)
  local model = decodeModelWithScalingRule(2, nodeDict, nodeData, sbc)
  local err = Assert.throws(function() NsbmdStaticTransforms.evaluate(model) end)
  Assert.equal(err.code, "NSBMD_STATIC_UNSUPPORTED_SCALING_RULE")
end

function T.accepts_the_maya_scaling_rule()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x04, 0) .. string.char(0x05, 0)
    .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(
    decodeModelWithScalingRule(1, nodeDict, nodeData, sbc))
  Assert.equal(#draws, 1)
  assertMatrixClose(draws[1].matrix, Matrix4.identity())
end

-- NODEDESC byte 3 carries the Maya scale-compensate bits, so a nonzero value
-- under the standard rule means the model was misread.
function T.rejects_nodedesc_flags_under_the_standard_rule()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0x01) .. string.char(0x01)
  local err = Assert.throws(function()
    NsbmdStaticTransforms.evaluate(decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000))
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
  local sbc = string.char(0x06, 0, 0, 0)  -- NODEDESC node0
    .. string.char(0x02, 0, 1)            -- NODE node0 visible
    .. string.char(0x07, 0)               -- BB node0, option 0
    .. (extraAfterBB or "")
    .. string.char(0x04, 0)               -- MAT 0
    .. string.char(0x05, 0)               -- SHP 0
    .. string.char(0x01)
  return decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000)
end

function T.billboard_reports_the_captured_joint_matrix()
  local draws = NsbmdStaticTransforms.evaluate(billboardModel())
  Assert.equal(#draws, 1)
  Assert.equal(draws[1].transformMode, "billboard")
  assertMatrixClose(draws[1].matrix, Matrix4.identity(),
    "billboard geometry stays in billboard-local space")
  -- Base = T(2,5,0) * S(3,1,1): the translation the runtime places the billboard
  -- at, and the per-axis scale it stretches by.
  assertMatrixAtPoint(draws[1].baseTransform, 0, 0, 0, 2, 5, 0, "base translation")
  assertMatrixAtPoint(draws[1].baseTransform, 1, 0, 0, 5, 5, 0, "base x scale")
end

function T.static_draws_report_static_mode()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0) .. string.char(0x04, 0) .. string.char(0x05, 0)
    .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000))
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
    .. string.char(0x07, 0)  -- BB
    .. string.char(0x05, 0)  -- SHP 0 (billboard)
    .. string.char(0x03, 0)  -- MTX restore slot 0
    .. string.char(0x05, 0)  -- SHP 0 (static again)
    .. string.char(0x01)
  local draws = NsbmdStaticTransforms.evaluate(decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000))
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
  local model = decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000)
  local err = Assert.throws(function() NsbmdStaticTransforms.evaluate(model) end)
  Assert.equal(err.code, "NSBMD_STATIC_BILLBOARD_MATRIX_SLOT_UNSUPPORTED")
end

-- No model in the target world issues BBY, so its yaw-only semantics are
-- deliberately unimplemented rather than guessed at.
function T.rejects_y_billboard_command()
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x08, 0) -- BBY
    .. string.char(0x01)
  local model = decodeModel(nodeDict, nodeData, sbc, 0x1000, 0x1000)
  local err = Assert.throws(function() NsbmdStaticTransforms.evaluate(model) end)
  Assert.equal(err.code, "NSBMD_STATIC_UNSUPPORTED_SBC_COMMAND")
end

return T
