-- MeshCompiler: evaluates the static SBC matrix state, replays each shape
-- display list with the material-seeded GX state and the draw's matrix/
-- restore-stack snapshot, converts already-transformed model units to tiles,
-- resolves a color source per vertex, carries the material's effective
-- polygon-attr word, and rejects a missing shape or unsupported in-DL command.

local Assert = require("tests.support.Assert")
local MeshCompiler = require("romdump.src.digest.MeshCompiler")
local Errors = require("libs.rom.src.Errors")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local NsbmdStaticTransforms = require("romdump.src.digest.NsbmdStaticTransforms")
local Matrix4 = require("libs.math.src.Matrix4")
local NB = require("tests.support.NitroBuilder")

local T = {}

local function u32(v) return NB.u32(v) end
local function u16(v) return NB.u16(v) end
local function u8(v) return NB.u8(v) end

-- Pack a VTX_16 (two words) from fx16 1.3.12 coordinates.
local function vtx16(x, y, z)
  local function raw(c) return math.floor(c * 4096) % 0x10000 end
  return u32(raw(x) + raw(y) * 0x10000) .. u32(raw(z))
end

-- A one-triangle display list with an optional leading COLOR or NORMAL command.
-- lead: "color" | "normal" | nil.
local function triangleDL(lead)
  if lead == "color" then
    -- COLOR, BEGIN, VTX, VTX | VTX, END, NOP, NOP
    return string.char(0x20, 0x40, 0x23, 0x23)
      .. u32(31) .. u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1)
      .. string.char(0x23, 0x41, 0, 0) .. vtx16(0, 0, 0)
  elseif lead == "normal" then
    return string.char(0x21, 0x40, 0x23, 0x23)
      .. u32(0) .. u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1)
      .. string.char(0x23, 0x41, 0, 0) .. vtx16(0, 0, 0)
  else -- no color/normal: vertices inherit the material's set-vertex-color seed
    return string.char(0x40, 0x23, 0x23, 0x23)
      .. u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1) .. vtx16(0, 0, 0)
      .. string.char(0x41, 0, 0, 0)
  end
end

local function buildMaterialBlock(polyAttrRaw)
  local diffAmb = 0x1F + 0x8000 + 0x03E0 * 0x10000
  local specEmi = 0x7C00 + 0x3DEF * 0x10000
  local matData = u16(0) .. u16(0x2C) .. u32(diffAmb) .. u32(specEmi)
    .. u32(polyAttrRaw or 0x001F00C1) .. u32(0xFFFFFFFF)
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
  local matDict = NB.dict({ { name = "mat", data = u16(ofsMatData) .. u16(0) } })

  return u16(4 + #matDict) .. u16(4 + #matDict + #texDict)
    .. matDict .. texDict .. pltDict .. string.char(0, 0)
    .. matData
end

local function buildShapeBlock(dl)
  local shpDict0 = NB.dict({ { name = "shp0", data = u32(0) } })
  local shapeDataOffset = #shpDict0
  local shapeData = u32(0) .. u32(0) .. u32(16) .. u32(#dl)
  local shpDict = NB.dict({ { name = "shp", data = u32(shapeDataOffset) } })
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

local function buildModelDict(model)
  local modelDict0 = NB.dict({ { name = "m0", data = u32(0) } })
  local modelOffset = 8 + #modelDict0
  local modelDict = NB.dict({ { name = "m", data = u32(modelOffset) } })
  return modelDict .. model
end

-- Model layout: header(0x14) + info(0x2C) + nodeDict + nodeData + sbc + matBlock + shpBlock.
local function buildModel(numNode, nodeDict, nodeData, sbc, posScale, invPosScale, dl, polyAttrRaw)
  local matBlock = buildMaterialBlock(polyAttrRaw)
  local shpBlock = buildShapeBlock(dl or triangleDL())
  local info = buildInfo(numNode, 1, 1, posScale, invPosScale)

  local ofsSbc = 0x40 + #nodeDict + #nodeData
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock

  local body = string.rep("\0", 0x14) .. info .. nodeDict .. nodeData .. sbc .. matBlock .. shpBlock
  local model = u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(0)
    .. body:sub(0x15)
  return model
end

local function decodeModel(numNode, nodeDict, nodeData, sbc, posScale, invPosScale, dl, polyAttrRaw)
  local model = buildModel(numNode, nodeDict, nodeData, sbc, posScale, invPosScale, dl, polyAttrRaw)
  local file = NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(model) } })
  local m = assert(Nsbmd.decode(file))
  return m.models[1]
end

-- Default model: one identity node, one material (index 0), one shape (index 0),
-- NODEDESC + NODE + POSSCALE + MAT + SHP + RET.
local function model(lead, posScale, invPosScale)
  posScale = posScale or 0x4000 -- 4.0
  invPosScale = invPosScale or 0x0400 -- 0.25
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)   -- NODEDESC node0 parent0 flags0
    .. string.char(0x02, 0, 1)             -- NODE node0 visible
    .. string.char(0x0B)                   -- POSSCALE normal
    .. string.char(0x04, 0)                -- MAT 0
    .. string.char(0x05, 0)                -- SHP 0
    .. string.char(0x01)                   -- RET
  return decodeModel(1, nodeDict, nodeData, sbc, posScale, invPosScale, triangleDL(lead))
end

function T.folds_posscale_and_carries_attributes()
  -- posScale 64.0, invPosScale 1/64.0 -> vertex x=1 becomes 64 model units, /16 = 4 tiles.
  local b = MeshCompiler.compile(model("color", 0x40000, 0x0040))
  Assert.equal(#b, 1)
  Assert.equal(b[1].materialIndex, 0)
  Assert.equal(b[1].nodeIndex, 0)
  Assert.equal(b[1].submissionIndex, 1)
  Assert.isTrue(math.abs(b[1].vertices[1].x - (1 * 64 / 16)) < 1e-9, "x scaled by posScale then divided by tile size")
  Assert.deepEqual(b[1].indices, { 0, 1, 2 })
end

function T.resolves_literal_color_source()
  local b = MeshCompiler.compile(model("color"))
  for _, v in ipairs(b[1].vertices) do
    Assert.equal(v.colorSource, 0) -- LITERAL
    Assert.equal(v.r, 255)         -- COLOR rgb555(31,0,0)
  end
end

function T.resolves_normal_lit_source()
  local b = MeshCompiler.compile(model("normal"))
  for _, v in ipairs(b[1].vertices) do
    Assert.equal(v.colorSource, 1) -- NORMAL_LIT
  end
end

function T.seeds_field_diffuse_when_no_color_or_normal()
  local b = MeshCompiler.compile(model(nil))
  for _, v in ipairs(b[1].vertices) do
    Assert.equal(v.colorSource, 2) -- FIELD_DIFFUSE from set-vertex-color material
    Assert.equal(v.r, 255)         -- material diffuse rgb555(31,0,0)
  end
end

function T.carries_effective_polygon_attr()
  local b = MeshCompiler.compile(model("color"))
  -- Full field global 0 + material mask 0x3F1FF8FF over raw 0x001F00C1.
  Assert.equal(b[1].polygonAttrRaw, 0x001F00C1)
end

function T.missing_shape_raises()
  local m = model("color")
  for _, cmd in ipairs(m.sbc.commands) do
    if cmd.opcode == 0x05 then -- SHP
      cmd.args[1] = 9
      cmd.shapeIndex = 9
    end
  end
  local ok, err = pcall(MeshCompiler.compile, m)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_MISSING_SHAPE", "raises")
end

function T.unsupported_dl_command_raises()
  -- Inject a SHININESS (0x34, 32 param words) before END: unsupported for fields.
  local dl = string.char(0x20, 0x40, 0x23, 0x23)
    .. NB.u32(31) .. NB.u32(0) .. vtx16(1, 0, 0) .. vtx16(0, 0, 1)
    .. string.char(0x23, 0x34, 0x41, 0) .. vtx16(0, 0, 0) .. string.rep(NB.u32(0), 32)
  local m = model("color")
  m.shapes[1].displayListBytes = dl
  local ok, err = pcall(MeshCompiler.compile, m)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_SHININESS_UNSUPPORTED",
    "rejects in-DL shininess")
end

function T.unsupported_polygon_mode_raises()
  -- Mode bits 4-5 = 2 (toon/highlight) is not supported for field rendering.
  local nodeDict, nodeData = identityNodeDictAndData()
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x0B)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  local m = decodeModel(1, nodeDict, nodeData, sbc, 0x4000, 0x0400, triangleDL("color"), 0x001F00E1)
  local ok, err = pcall(MeshCompiler.compile, m)
  Assert.isTrue(not ok and Errors.is(err) and err.code == "MAP_COMPILE_UNSUPPORTED_POLYGON_MODE",
    "rejects toon polygon mode")
end

function T.full_path_vertex_through_node_posscale_and_tiles()
  -- Node: translate (2,0,0), scale (2,1,1); posScale = 4.0.
  -- The static evaluator produces the draw matrix; MeshCompiler must emit the
  -- same transformed vertex divided by MODEL_UNITS_PER_TILE.
  local nodeData = transformedNodeData(2, 0, 0, 2, 1, 1)
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDataOffset = #nodeDict0
  local nodeDict = NB.dict({ { name = "root", data = u32(nodeDataOffset) } })
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x0B)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  local m = decodeModel(1, nodeDict, nodeData, sbc, 0x4000, 0x0400, triangleDL("color"))
  local draws = NsbmdStaticTransforms.evaluate(m)
  Assert.equal(#draws, 1)
  local expectedX, expectedY = Matrix4.transformPoint(draws[1].matrix, 1, 0, 0)
  expectedX = expectedX / 16
  expectedY = expectedY / 16

  local b = MeshCompiler.compile(m)
  Assert.equal(#b, 1)
  -- triangleDL("color") vertices: (1,0,0), (0,0,1), (0,0,0)
  Assert.isTrue(math.abs(b[1].vertices[1].x - expectedX) < 1e-9,
    "vertex transformed by node SRT, POSSCALE, then tile divisor")
  Assert.isTrue(math.abs(b[1].vertices[1].y - expectedY) < 1e-9, "y unchanged")
end

function T.wind_like_large_posscale_compensated_by_node_scale()
  -- Wind has a large posScale but its node scale compensates.
  -- Node scale 0.25 * posScale 64 = effective scale 16; /16 tiles = 1.0.
  local nodeData = transformedNodeData(0, 0, 0, 0.25, 0.25, 0.25)
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDataOffset = #nodeDict0
  local nodeDict = NB.dict({ { name = "root", data = u32(nodeDataOffset) } })
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x0B)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  local m = decodeModel(1, nodeDict, nodeData, sbc, 0x40000, 0x0040, triangleDL("color"))
  local b = MeshCompiler.compile(m)
  Assert.equal(#b, 1)
  Assert.isTrue(math.abs(b[1].vertices[1].x - 1.0) < 1e-9,
    "large posScale compensated by node scale yields sane tile size")
  Assert.isTrue(math.abs(b[1].vertices[2].z - 1.0) < 1e-9,
    "large posScale compensated by node scale yields sane tile size")
end

return T
