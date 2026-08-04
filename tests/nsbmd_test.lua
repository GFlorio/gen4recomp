-- Synthetic MDL0 test. Assembles a minimal but structurally real BMD0 (one
-- model, one node, one textured material, one shape with a triangle display
-- list, and an SBC draw stream) and checks that Nsbmd recovers the info
-- counts, node/material names, texture/palette associations, shape geometry,
-- and the SBC draw instances.

local Assert = require("tests.support.Assert")
local Nsbmd = require("src.data.nitro.Nsbmd")
local NB = require("tests.support.NitroBuilder")
local Matrix4 = require("src.render.Matrix4")

local T = {}

local function u32(v) return NB.u32(v) end

-- One-triangle display list (BEGIN triangles, 3x VTX_16, END).
local function triangleDL()
  local function vtx16(x, y, z)
    local function raw(c) return math.floor(c * 4096) % 0x10000 end
    return NB.u32(raw(x) + raw(y) * 0x10000) .. NB.u32(raw(z))
  end
  -- command group 1: 0x40 BEGIN, 0x23,0x23,0x23 ; group 2: 0x41 END, NOP,NOP,NOP
  return string.char(0x40, 0x23, 0x23, 0x23) .. NB.u32(0)
    .. vtx16(0, 0, 0) .. vtx16(2, 0, 0) .. vtx16(0, 3, 0)
    .. string.char(0x41, 0, 0, 0)
end

local function buildMaterialBlock()
  -- NNSG3dResMatData prefix (0x2C bytes), distinct value in every field.
  --   diffAmb : diffuse rgb555(31,0,0)=0x1F, set-vertex-color bit15, ambient
  --             rgb555(0,31,0)=0x3E0 -> word 0x03E081F.. with bit15 -> +0x8000
  --   specEmi : specular rgb555(0,0,31)=0x7C00, emission rgb555(15,15,15)=0x3DEF
  --   polyAttr: 0x001F00C1 (lightMask 1, front render, alpha 31), full mask
  --   flags   : diffuse+vertexColor ownership (0x40 | 0x100 = 0x140)
  --   texImageParam at 0x14 requests repeat S/T (bits 16-17), full mask;
  --   origWidth/Height at 0x20/0x22; magW/magH fx32 1.0 at 0x24/0x28.
  local diffAmb = 0x1F + 0x8000 + 0x03E0 * 0x10000
  local specEmi = 0x7C00 + 0x3DEF * 0x10000
  local matData = NB.u16(0) .. NB.u16(0x2C) .. NB.u32(diffAmb) .. NB.u32(specEmi)
    .. NB.u32(0x001F00C1) .. NB.u32(0xFFFFFFFF)
    .. NB.u32(0x30000) .. NB.u32(0xFFFFFFFF) .. NB.u16(0) .. NB.u16(0x140)
    .. NB.u16(8) .. NB.u16(16) .. NB.u32(0x1000) .. NB.u32(0x1000)

  -- texToMat / plttToMat: name -> u8[count] material indices placed after the
  -- dicts in the material block. Entry data: u16 ofsList, u8 count, u8 bound.
  local texToMatEntry = function(ofsList) return NB.u16(ofsList) .. string.char(1, 0) end

  -- Two-pass sizing: the binding dicts and material data block all live in the
  -- same material section, so their offsets depend on each other's sizes.
  local matDict0 = NB.dict({ { name = "mat0", data = u32(0) } })
  local texDict0 = NB.dict({ { name = "tex0", data = texToMatEntry(0) } })
  local pltDict0 = NB.dict({ { name = "pal0", data = texToMatEntry(0) } })
  local listBase = 4 + #matDict0 + #texDict0 + #pltDict0 + 2

  local texDict = NB.dict({ { name = "tex0", data = texToMatEntry(listBase) } })
  local pltDict = NB.dict({ { name = "pal0", data = texToMatEntry(listBase + 1) } })
  local ofsMatData = 4 + #matDict0 + #texDict + #pltDict + 2
  local matDict = NB.dict({ { name = "mat0", data = NB.u16(ofsMatData) .. NB.u16(0) } })

  return NB.u16(4 + #matDict) .. NB.u16(4 + #matDict + #texDict)
    .. matDict .. texDict .. pltDict .. string.char(0, 0) -- tex0->[0], pal0->[0]
    .. matData
end

local function buildShapeBlock(dl)
  local shpDict0 = NB.dict({ { name = "shp0", data = u32(0) } })
  local shapeDataOffset = #shpDict0
  local shapeData = u32(0) .. u32(0) .. u32(16) .. u32(#dl) -- flags, flags, ofsDL=16, sizeDL
  local shpDict = NB.dict({ { name = "shp0", data = u32(shapeDataOffset) } })
  return shpDict .. shapeData .. dl
end

local function buildInfo(numNode, numMat, numShp)
  local fields = {}
  fields[#fields + 1] = NB.u8(0)  -- sbcType
  fields[#fields + 1] = NB.u8(0)  -- scalingRule
  fields[#fields + 1] = NB.u8(0)  -- texMtxMode
  fields[#fields + 1] = NB.u8(numNode)
  fields[#fields + 1] = NB.u8(numMat)
  fields[#fields + 1] = NB.u8(numShp)
  fields[#fields + 1] = NB.u8(0)  -- firstUnusedMtxStackID
  fields[#fields + 1] = NB.u8(0)  -- dummy
  fields[#fields + 1] = NB.u32(0x1000) -- posScale
  fields[#fields + 1] = NB.u32(0x2000) -- invPosScale
  fields[#fields + 1] = NB.u16(3)  -- numVertex
  fields[#fields + 1] = NB.u16(1)  -- numPolygon
  fields[#fields + 1] = NB.u16(1)  -- numTriangle
  fields[#fields + 1] = NB.u16(0)  -- numQuad
  for i = 1, 6 do fields[#fields + 1] = NB.u16(0) end -- box x,y,z,w,h,d
  fields[#fields + 1] = NB.u32(0x4000) -- boxPosScale
  fields[#fields + 1] = NB.u32(0x0800) -- boxInvPosScale
  return table.concat(fields)
end

-- Model layout: header(0x14) + info(0x2C) + nodeDict + nodeData + sbc + matBlock + shpBlock.
local function buildModel(nodeDict, nodeData, sbc)
  local matBlock = buildMaterialBlock()
  local shpBlock = buildShapeBlock(triangleDL())
  local info = buildInfo(1, 1, 1)

  local ofsSbc = 0x40 + #nodeDict + #nodeData
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock

  local body = string.rep("\0", 0x14) .. info .. nodeDict .. nodeData .. sbc .. matBlock .. shpBlock
  local model = u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(0)
    .. body:sub(0x15) -- replace the zeroed header region with real offsets

  return model
end

local function buildModelDict(model)
  local modelDict0 = NB.dict({ { name = "m0", data = u32(0) } })
  local modelOffset = 8 + #modelDict0
  local modelDict = NB.dict({ { name = "m0", data = u32(modelOffset) } })
  return modelDict .. model
end

local function buildBmd0()
  -- Identity node: flags = TRANS_ZERO | ROT_ZERO | SCALE_ONE, _00 = 0.
  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDataOffset = #nodeDict0
  local nodeDict = NB.dict({ { name = "root", data = u32(nodeDataOffset) } })
  local nodeData = NB.u16(0x0007) .. NB.u16(0)

  -- NODEDESC(root), NODE(0,vis), POSSCALE, MAT/SHP, POSSCALE(inverse), MAT/SHP, RET.
  local sbc = string.char(0x06, 0, 0, 0)          -- NODEDESC node0 parent0 flags0
    .. string.char(0x02, 0, 1)                    -- NODE node0 vis1
    .. string.char(0x0B)                          -- POSSCALE (normal)
    .. string.char(0x04, 0)                       -- MAT 0
    .. string.char(0x05, 0)                       -- SHP 0
    .. string.char(0x2B)                          -- POSSCALE (inverse)
    .. string.char(0x04, 0)                       -- MAT 0
    .. string.char(0x05, 0)                       -- SHP 0
    .. string.char(0x01)                          -- RET

  local model = buildModel(nodeDict, nodeData, sbc)
  return NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(model) } })
end

local function buildTransformedBmd0()
  -- One node with translation (2,0,0), identity rotation, scale (2,1,1).
  local nodeData = NB.u16(0x0000) .. NB.u16(0x1000) -- flags=0, _00=1.0
    .. NB.u32(0x2000) .. NB.u32(0) .. NB.u32(0)   -- translation
    .. NB.u16(0) .. NB.u16(0) .. NB.u16(0)        -- rotation col0 rows 1,2 + col1 row0
    .. NB.u16(0x1000) .. NB.u16(0) .. NB.u16(0)   -- col1 row1, row2 + col2 row0
    .. NB.u16(0) .. NB.u16(0x1000)                -- col2 row1, row2
    .. NB.u32(0x2000) .. NB.u32(0x1000) .. NB.u32(0x1000) -- scale

  local nodeDict0 = NB.dict({ { name = "root", data = u32(0) } })
  local nodeDataOffset = #nodeDict0
  local nodeDict = NB.dict({ { name = "root", data = u32(nodeDataOffset) } })

  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x0B)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)

  local model = buildModel(nodeDict, nodeData, sbc)
  return NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(model) } })
end

function T.decodes_model_info_and_names()
  local m = assert(Nsbmd.decode(buildBmd0()))
  Assert.equal(#m.models, 1)
  local model = m.models[1]
  Assert.equal(model.name, "m0")
  Assert.equal(model.info.numNode, 1)
  Assert.equal(model.info.numMat, 1)
  Assert.equal(model.info.numShp, 1)
  Assert.equal(model.info.sbcType, 0)
  Assert.equal(model.info.scalingRule, 0)
  Assert.equal(model.info.texMtxMode, 0)
  Assert.equal(model.info.firstUnusedMtxStackID, 0)
  Assert.equal(model.info.posScale, 1)
  Assert.equal(model.info.invPosScale, 2)
  Assert.equal(model.info.boxPosScale, 4)
  Assert.equal(model.info.boxInvPosScale, 0.5)
  Assert.equal(model.nodes[1].name, "root")
  Assert.equal(model.nodes[1].flagsRaw, 0x0007)
  Assert.equal(model.nodes[1].matrixStackIndex, 0)
  Assert.equal(model.materials[1].name, "mat0")
end

function T.parses_material_texparam_and_wrap()
  local mat = assert(Nsbmd.decode(buildBmd0())).models[1].materials[1]
  Assert.equal(mat.texImageParamRaw, 0x30000)
  Assert.equal(mat.texImageParamMask, 0xFFFFFFFF)
  Assert.isTrue(mat.repeatX and mat.repeatY, "repeat S/T derived from texImageParam")
  Assert.isFalse(mat.flipX)
  Assert.isFalse(mat.flipY)
  Assert.equal(mat.origWidth, 8)
  Assert.equal(mat.origHeight, 16)
  Assert.equal(mat.magW, 1.0)
  Assert.equal(mat.magH, 1.0)
end

function T.parses_full_material_prefix()
  local mat = assert(Nsbmd.decode(buildBmd0())).models[1].materials[1]
  Assert.equal(mat.itemTag, 0)
  Assert.equal(mat.size, 0x2C)
  Assert.equal(mat.polyAttrRaw, 0x001F00C1)
  Assert.equal(mat.polyAttrMask, 0xFFFFFFFF)
  Assert.equal(mat.flagsRaw, 0x140)
  Assert.equal(mat.extraBytes, "")
  -- Decoded lighting channels.
  Assert.equal(mat.diffuseRgb555, 0x1F)
  Assert.equal(mat.ambientRgb555, 0x03E0)
  Assert.equal(mat.specularRgb555, 0x7C00)
  Assert.equal(mat.emissionRgb555, 0x3DEF)
  Assert.isTrue(mat.setVertexColor)
  Assert.isFalse(mat.useShininessTable)
  -- Ownership from flags 0x140 = diffuse | vertexColor.
  Assert.isTrue(mat.owns.diffuse)
  Assert.isTrue(mat.owns.vertexColor)
  Assert.isFalse(mat.owns.ambient)
  Assert.isFalse(mat.owns.specular)
  Assert.isFalse(mat.owns.emission)
  Assert.isFalse(mat.owns.shininess)
end

function T.recovers_texture_and_palette_associations()
  local model = assert(Nsbmd.decode(buildBmd0())).models[1]
  Assert.equal(model.materials[1].textureName, "tex0")
  Assert.equal(model.materials[1].paletteName, "pal0")
  Assert.equal(model.textureAssociations[1].name, "tex0")
  Assert.deepEqual(model.textureAssociations[1].materials, { 0 })
end

function T.decodes_shape_geometry()
  local model = assert(Nsbmd.decode(buildBmd0())).models[1]
  Assert.equal(#model.shapes, 1)
  local shp = model.shapes[1]
  Assert.equal(shp.name, "shp0")
  Assert.equal(shp.vertexCount, 3)
  Assert.equal(shp.triangleCount, 1)
  Assert.deepEqual(shp.bounds.max, { 2, 3, 0 })
  Assert.notNil(model.bounds)
end

function T.decodes_sbc_draw_instances()
  local model = assert(Nsbmd.decode(buildBmd0())).models[1]
  Assert.equal(#model.sbc.draws, 2)
  Assert.equal(model.sbc.draws[1].materialIndex, 0)
  Assert.equal(model.sbc.draws[1].shapeIndex, 0)
  Assert.equal(model.sbc.draws[1].nodeIndex, 0)
  Assert.isTrue(model.sbc.draws[1].materialReapplied)
  Assert.equal(model.sbc.draws[2].materialIndex, 0)
  Assert.equal(model.sbc.draws[2].shapeIndex, 0)
  Assert.equal(model.sbc.draws[2].nodeIndex, 0)
  Assert.isTrue(model.sbc.draws[2].materialReapplied)
  Assert.equal(model.sbc.opcodeCounts[0x05], 2) -- two SHP
  Assert.equal(model.sbc.opcodeCounts[0x01], 1) -- one RET

  local nd = model.sbc.commands[1]
  Assert.equal(nd.name, "NODEDESC")
  Assert.equal(nd.nodeIndex, 0)
  Assert.equal(nd.parentIndex, 0)
  Assert.equal(nd.flags, 0)

  local poss = {}
  for _, c in ipairs(model.sbc.commands) do
    if c.opcode == 0x0B then poss[#poss + 1] = c end
  end
  Assert.equal(#poss, 2)
  Assert.isFalse(poss[1].inverse)
  Assert.isTrue(poss[2].inverse)
end

function T.decodes_identity_node_srt()
  local model = assert(Nsbmd.decode(buildBmd0())).models[1]
  local node = model.nodes[1]
  Assert.equal(node.name, "root")
  Assert.equal(node.flagsRaw, 0x0007)
  Assert.equal(node.matrixStackIndex, 0)
  Assert.deepEqual(node.translation, { x = 0, y = 0, z = 0 })
  Assert.deepEqual(node.scale, { x = 1, y = 1, z = 1 })
  Assert.deepEqual(node.rotation, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  Assert.deepEqual(node.localMatrix, Matrix4.identity())
end

function T.decodes_transformed_node_srt()
  local model = assert(Nsbmd.decode(buildTransformedBmd0())).models[1]
  local node = model.nodes[1]
  Assert.equal(node.translation.x, 2)
  Assert.equal(node.translation.y, 0)
  Assert.equal(node.translation.z, 0)
  Assert.equal(node.scale.x, 2)
  Assert.equal(node.scale.y, 1)
  Assert.equal(node.scale.z, 1)
  Assert.deepEqual(node.rotation, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })

  local x, y, z = Matrix4.transformPoint(node.localMatrix, 1, 0, 0)
  Assert.equal(x, 4)
  Assert.equal(y, 0)
  Assert.equal(z, 0)
end

function T.rejects_malformed_node_data_offset()
  local nodeDict = NB.dict({ { name = "root", data = u32(0) } })
  local nodeData = ""
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x0B)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  local model = buildModel(nodeDict, nodeData, sbc)
  local m, err = Nsbmd.decode(NB.file("BMD0", { { magic = "MDL0", body = buildModelDict(model) } }))
  Assert.isNil(m)
  Assert.equal(err.code, "NSBMD_NODE_DATA_OFFSET_ZERO")
end

function T.rejects_missing_mdl0()
  local bytes = NB.file("BMD0", { { magic = "TEX0", body = string.rep("\0", 60) } })
  local m, err = Nsbmd.decode(bytes)
  Assert.isNil(m)
  Assert.equal(err.code, "NSBMD_NO_MDL0")
end

return T
