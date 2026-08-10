-- NsbmdModelFixture: shared builders for multi-node NSBMD fixture models --
-- real BMD0 bytes that Nsbmd.decode consumes, with caller-supplied node
-- records, SBC streams, scaling rules, and inverse-bind blocks. This is the
-- builder layer above NsbmdFixture (which is single-node); the SBC evaluator
-- tests on both sides of the digest/engine boundary build their decoded
-- models here. Test-only.

local NB = require("tests.support.NitroBuilder")

local NsbmdModelFixture = {}

local function u32(v)
  return NB.u32(v)
end
local function u16(v)
  return NB.u16(v)
end
local function u8(v)
  return NB.u8(v)
end

local function fx32(v)
  return u32(math.floor(v * 4096))
end

-- One-triangle display list (BEGIN triangles, 3x VTX_16, END).
function NsbmdModelFixture.triangleDL()
  local function vtx16(x, y, z)
    local function raw(c)
      return math.floor(c * 4096) % 0x10000
    end
    return u32(raw(x) + raw(y) * 0x10000) .. u32(raw(z))
  end
  return string.char(0x40, 0x23, 0x23, 0x23)
    .. u32(0)
    .. vtx16(0, 0, 0)
    .. vtx16(1, 0, 0)
    .. vtx16(0, 1, 0)
    .. string.char(0x41, 0, 0, 0)
end

function NsbmdModelFixture.buildMaterialBlock()
  local diffAmb = 0x1F + 0x8000 + 0x03E0 * 0x10000
  local specEmi = 0x7C00 + 0x3DEF * 0x10000
  local matData = u16(0)
    .. u16(0x2C)
    .. u32(diffAmb)
    .. u32(specEmi)
    .. u32(0x001F00C1)
    .. u32(0xFFFFFFFF)
    .. u32(0x30000)
    .. u32(0xFFFFFFFF)
    .. u16(0)
    .. u16(0x140)
    .. u16(8)
    .. u16(16)
    .. u32(0x1000)
    .. u32(0x1000)

  local texToMatEntry = function(ofsList)
    return u16(ofsList) .. string.char(1, 0)
  end

  local matDict0 = NB.dict({ { name = "mat0", data = u32(0) } })
  local texDict0 = NB.dict({ { name = "tex0", data = texToMatEntry(0) } })
  local pltDict0 = NB.dict({ { name = "pal0", data = texToMatEntry(0) } })
  local listBase = 4 + #matDict0 + #texDict0 + #pltDict0 + 2

  local texDict = NB.dict({ { name = "tex0", data = texToMatEntry(listBase) } })
  local pltDict = NB.dict({ { name = "pal0", data = texToMatEntry(listBase + 1) } })
  local ofsMatData = 4 + #matDict0 + #texDict + #pltDict + 2
  local matDict = NB.dict({ { name = "mat0", data = u16(ofsMatData) .. u16(0) } })

  return u16(4 + #matDict)
    .. u16(4 + #matDict + #texDict)
    .. matDict
    .. texDict
    .. pltDict
    .. string.char(0, 0)
    .. matData
end

function NsbmdModelFixture.buildShapeBlock(dl)
  local shpDict0 = NB.dict({ { name = "shp0", data = u32(0) } })
  local shapeDataOffset = #shpDict0
  local shapeData = u32(0) .. u32(0) .. u32(16) .. u32(#dl)
  local shpDict = NB.dict({ { name = "shp0", data = u32(shapeDataOffset) } })
  return shpDict .. shapeData .. dl
end

function NsbmdModelFixture.buildInfo(numNode, numMat, numShp, posScale, invPosScale)
  local fields = {}
  fields[#fields + 1] = u8(0) -- sbcType
  fields[#fields + 1] = u8(0) -- scalingRule
  fields[#fields + 1] = u8(0) -- texMtxMode
  fields[#fields + 1] = u8(numNode)
  fields[#fields + 1] = u8(numMat)
  fields[#fields + 1] = u8(numShp)
  fields[#fields + 1] = u8(0) -- firstUnusedMtxStackID
  fields[#fields + 1] = u8(0) -- dummy
  fields[#fields + 1] = u32(posScale or 0x1000)
  fields[#fields + 1] = u32(invPosScale or 0x1000)
  fields[#fields + 1] = u16(3) -- numVertex
  fields[#fields + 1] = u16(1) -- numPolygon
  fields[#fields + 1] = u16(1) -- numTriangle
  fields[#fields + 1] = u16(0) -- numQuad
  for i = 1, 6 do
    fields[#fields + 1] = u16(0)
  end -- box x,y,z,w,h,d
  fields[#fields + 1] = u32(0x4000) -- boxPosScale
  fields[#fields + 1] = u32(0x0800) -- boxInvPosScale
  return table.concat(fields)
end

function NsbmdModelFixture.buildModelDict(model)
  local modelDict0 = NB.dict({ { name = "m0", data = u32(0) } })
  local modelOffset = 8 + #modelDict0
  local modelDict = NB.dict({ { name = "m0", data = u32(modelOffset) } })
  return modelDict .. model
end

-- Model layout: header(0x14) + info(0x2C) + nodeDict + nodeData + sbc + matBlock + shpBlock [+ evpBlock].
-- opts: posScale, invPosScale, numNode, numMat, numShp, evpBlock (raw bytes).
function NsbmdModelFixture.buildModel(nodeDict, nodeData, sbc, opts)
  opts = opts or {}
  local numNode = opts.numNode or 1
  local numMat = opts.numMat or 1
  local numShp = opts.numShp or 1
  local matBlock = NsbmdModelFixture.buildMaterialBlock()
  local shpBlock = NsbmdModelFixture.buildShapeBlock(NsbmdModelFixture.triangleDL())
  local info = NsbmdModelFixture.buildInfo(numNode, numMat, numShp, opts.posScale, opts.invPosScale)

  local ofsSbc = 0x40 + #nodeDict + #nodeData
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock
  local ofsEvp = opts.evpBlock and (ofsShp + #shpBlock) or 0

  local body = string.rep("\0", 0x14)
    .. info
    .. nodeDict
    .. nodeData
    .. sbc
    .. matBlock
    .. shpBlock
    .. (opts.evpBlock or "")
  return u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(ofsEvp) .. body:sub(0x15)
end

local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")

-- Decode a fixture model with the given node dict/data and SBC stream.
function NsbmdModelFixture.decodeModel(nodeDict, nodeData, sbc, opts)
  local model = NsbmdModelFixture.buildModel(nodeDict, nodeData, sbc, opts)
  local file = NB.file("BMD0", { { magic = "MDL0", body = NsbmdModelFixture.buildModelDict(model) } })
  local m = assert(Nsbmd.decode(file))
  return m.models[1]
end

-- The same model with NNSG3dResMdlInfo.scalingRule overwritten. The info block
-- starts at model offset 0x14 and scalingRule is its second byte.
function NsbmdModelFixture.decodeModelWithScalingRule(rule, nodeDict, nodeData, sbc)
  local model = NsbmdModelFixture.buildModel(nodeDict, nodeData, sbc, { posScale = 0x1000, invPosScale = 0x1000 })
  model = model:sub(1, 0x15) .. string.char(rule) .. model:sub(0x17)
  local file = NB.file("BMD0", { { magic = "MDL0", body = NsbmdModelFixture.buildModelDict(model) } })
  return assert(Nsbmd.decode(file)).models[1]
end

-- An identity node record in matrix stack slot `slot`.
function NsbmdModelFixture.identityNodeDictAndData(slot)
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
function NsbmdModelFixture.transformedNodeData(tx, ty, tz, sx, sy, sz, slot)
  slot = slot or 0
  local flags = slot * 2048 -- no zero flags: translation, rotation, scale all present
  local data = u16(flags)
    .. u16(0x1000) -- _00 = 1.0 (a[1])
    .. fx32(tx)
    .. fx32(ty)
    .. fx32(tz)
    -- Remaining 8 components of the 3x3 rotation matrix (a[2]..a[9]), identity.
    .. u16(0)
    .. u16(0)
    .. u16(0)
    .. u16(0x1000)
    .. u16(0)
    .. u16(0)
    .. u16(0)
    .. u16(0x1000)
    .. fx32(sx)
    .. fx32(sy)
    .. fx32(sz)
  return data
end

-- ---- NODEMIX fixtures ----

-- One NNSG3dResEvpMtx: MtxFx43 invM (identity rotation plus `tx,ty,tz`) then
-- MtxFx33 invN. `invNScale` scales invN's diagonal, so 1 is a rigid bind pose
-- and anything else is not.
function NsbmdModelFixture.evpEntry(tx, ty, tz, invNScale)
  invNScale = invNScale or 1
  return fx32(1)
    .. fx32(0)
    .. fx32(0)
    .. fx32(0)
    .. fx32(1)
    .. fx32(0)
    .. fx32(0)
    .. fx32(0)
    .. fx32(1)
    .. fx32(tx)
    .. fx32(ty)
    .. fx32(tz)
    .. fx32(invNScale)
    .. fx32(0)
    .. fx32(0)
    .. fx32(0)
    .. fx32(invNScale)
    .. fx32(0)
    .. fx32(0)
    .. fx32(0)
    .. fx32(invNScale)
end

-- Two root joints in matrix slots 0 and 1, translated (10,0,0) and (0,20,0).
-- The SBC blends both slots with `sbcTail` and draws. `evpBlock` is the
-- model's inverse-bind array (raw bytes), or nil to omit it (ofsEvpMtx = 0).
function NsbmdModelFixture.nodemixModel(sbcTail, evpBlock)
  local node0Data = NsbmdModelFixture.transformedNodeData(10, 0, 0, 1, 1, 1, 0)
  local node1Data = NsbmdModelFixture.transformedNodeData(0, 20, 0, 1, 1, 1, 1)
  local nodeData = node0Data .. node1Data
  local nodeDict0 = NB.dict({
    { name = "a", data = u32(0) },
    { name = "b", data = u32(#node0Data) },
  })
  local nodeDict = NB.dict({
    { name = "a", data = u32(#nodeDict0) },
    { name = "b", data = u32(#nodeDict0 + #node0Data) },
  })
  local sbc = string.char(0x06, 0, 0, 0) -- NODEDESC node0 -> slot 0
    .. string.char(0x06, 1, 1, 0) -- NODEDESC node1 -> slot 1
    .. sbcTail
  return NsbmdModelFixture.decodeModel(nodeDict, nodeData, sbc, {
    numNode = 2,
    evpBlock = evpBlock,
  })
end

return NsbmdModelFixture
