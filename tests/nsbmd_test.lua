-- Synthetic MDL0 test. Assembles a minimal but structurally real BMD0 (one
-- model, one node, one textured material, one shape with a triangle display
-- list, and an SBC draw stream) and checks that Nsbmd recovers the info
-- counts, node/material names, texture/palette associations, shape geometry,
-- and the SBC draw instances.

local Assert = require("tests.support.Assert")
local Nsbmd = require("src.data.nitro.Nsbmd")
local NB = require("tests.support.NitroBuilder")

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

local function buildModel()
  -- Node / material / shape dictionaries.
  local nodeDict = NB.dict({ { name = "root", data = u32(0) } })
  local matDict = NB.dict({ { name = "mat0", data = u32(0) } }) -- offset patched below

  -- NNSG3dResMatData prefix (0x2C bytes): texImageParam at 0x14 requests repeat
  -- S/T (bits 16-17) with a full ownership mask; origWidth/Height at 0x20/0x22.
  local matData = NB.u16(0) .. NB.u16(0x2C) .. u32(0) .. u32(0) .. u32(0) .. u32(0)
    .. NB.u32(0x30000) .. NB.u32(0xFFFFFFFF) .. NB.u16(0) .. NB.u16(0)
    .. NB.u16(8) .. NB.u16(16) .. u32(0) .. u32(0)

  -- texToMat / plttToMat: name -> u8[count] material indices placed after the
  -- dicts in the material block. Entry data: u16 ofsList, u8 count, u8 bound.
  local ofsTexToMat = 4 + #matDict
  local texToMatEntry = function(ofsList) return NB.u16(ofsList) .. string.char(1, 0) end

  -- Provisionally size the two binding dicts (they hold one 4-byte entry each).
  local texDict = NB.dict({ { name = "tex0", data = texToMatEntry(0) } })
  local ofsPlttToMat = ofsTexToMat + #texDict
  local pltDict = NB.dict({ { name = "pal0", data = texToMatEntry(0) } })

  -- Material index arrays follow both binding dicts.
  local listBase = ofsPlttToMat + #pltDict
  -- Rebuild binding dicts with real ofsList values.
  texDict = NB.dict({ { name = "tex0", data = texToMatEntry(listBase) } })
  pltDict = NB.dict({ { name = "pal0", data = texToMatEntry(listBase + 1) } })
  -- Material data block follows the two index arrays; point mat0 at it.
  local ofsMatData = 4 + #matDict + #texDict + #pltDict + 2
  matDict = NB.dict({ { name = "mat0", data = NB.u16(ofsMatData) .. NB.u16(0) } })
  local matBlock = NB.u16(ofsTexToMat) .. NB.u16(ofsPlttToMat)
    .. matDict .. texDict .. pltDict .. string.char(0, 0) -- material indices: tex0->[0], pal0->[0]
    .. matData

  -- Shape block: dict -> shape data (ofsDL@8, sizeDL@12) -> DL bytes.
  local dl = triangleDL()
  local shpDict = NB.dict({ { name = "shp0", data = u32(0) } }) -- offset patched below
  local shapeDataOffset = #shpDict
  local shapeData = u32(0) .. u32(0) .. u32(16) .. u32(#dl) -- flags, flags, ofsDL=16, sizeDL
  shpDict = NB.dict({ { name = "shp0", data = u32(shapeDataOffset) } })
  local shpBlock = shpDict .. shapeData .. dl

  -- SBC: NODEDESC(root=0), NODE(0,vis), POSSCALE, MAT 0, SHP 0, RET.
  local sbc = string.char(0x06, 0, 0, 0) -- NODEDESC node0 parent0 flags0 (3 args)
    .. string.char(0x02, 0, 1) -- NODE node0 vis1
    .. string.char(0x0B) -- POSSCALE
    .. string.char(0x04, 0) -- MAT 0
    .. string.char(0x05, 0) -- SHP 0
    .. string.char(0x01) -- RET

  -- Model layout: header(0x14) + info(0x2C) + nodeDict + sbc + matBlock + shpBlock.
  local info = { string.rep("\0", 0x2C) }
  info = info[1]
  -- numNode/numMat/numShp at info +0x03/04/05; posScale (fx32 1.0) at +0x08.
  info = info:sub(1, 3) .. string.char(1, 1, 1) .. info:sub(7)
  info = info:sub(1, 8) .. NB.u32(0x1000) .. info:sub(13)

  local ofsSbc = 0x40 + #nodeDict
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock
  local body = string.rep("\0", 0x14) .. info .. nodeDict .. sbc .. matBlock .. shpBlock
  local model = u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(0)
    .. body:sub(0x15) -- replace the zeroed header region with real offsets

  return model
end

local function buildBmd0()
  local model = buildModel()
  local modelDict = NB.dict({ { name = "m0", data = u32(0) } }) -- offset patched
  local modelOffset = 8 + #modelDict
  modelDict = NB.dict({ { name = "m0", data = u32(modelOffset) } })
  local mdl0Body = modelDict .. model
  return NB.file("BMD0", { { magic = "MDL0", body = mdl0Body } })
end

function T.decodes_model_info_and_names()
  local m = assert(Nsbmd.decode(buildBmd0()))
  Assert.equal(#m.models, 1)
  local model = m.models[1]
  Assert.equal(model.name, "m0")
  Assert.equal(model.info.numNode, 1)
  Assert.equal(model.info.numMat, 1)
  Assert.equal(model.info.numShp, 1)
  Assert.equal(model.info.posScale, 1)
  Assert.equal(model.nodes[1].name, "root")
  Assert.equal(model.materials[1].name, "mat0")
end

function T.parses_material_texparam_and_wrap()
  local mat = assert(Nsbmd.decode(buildBmd0())).models[1].materials[1]
  Assert.equal(mat.texImageParam, 0x30000)
  Assert.isTrue(mat.repeatX and mat.repeatY, "repeat S/T derived from texImageParam")
  Assert.isFalse(mat.flipX)
  Assert.isFalse(mat.flipY)
  Assert.equal(mat.origWidth, 8)
  Assert.equal(mat.origHeight, 16)
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
  Assert.equal(#model.sbc.draws, 1)
  local draw = model.sbc.draws[1]
  Assert.equal(draw.materialIndex, 0)
  Assert.equal(draw.shapeIndex, 0)
  Assert.equal(model.sbc.opcodeCounts[0x05], 1) -- one SHP
  Assert.equal(model.sbc.opcodeCounts[0x01], 1) -- one RET
end

function T.rejects_missing_mdl0()
  local bytes = NB.file("BMD0", { { magic = "TEX0", body = string.rep("\0", 60) } })
  local m, err = Nsbmd.decode(bytes)
  Assert.isNil(m)
  Assert.equal(err.code, "NSBMD_NO_MDL0")
end

return T
