-- Synthetic MDL0 test. Uses NsbmdFixture's minimal but structurally real BMD0
-- (one model, one node, one textured material, one shape with a triangle
-- display list, and an SBC draw stream) and checks that Nsbmd recovers the info
-- counts, node/material names, texture/palette associations, shape geometry,
-- and the SBC draw instances.

local Assert = require("tests.support.Assert")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local NB = require("tests.support.NitroBuilder")
local Fixture = require("tests.support.NsbmdFixture")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function buildBmd0()
  return Fixture.build()
end
local function buildTransformedBmd0()
  return Fixture.buildTransformed()
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
    if c.opcode == 0x0B then
      poss[#poss + 1] = c
    end
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
  Assert.isTrue(node.transZero and node.rotZero and node.scaleOne)
  -- Only the standard rule's joints omit an inverse scale.
  Assert.isNil(node.inverseScale)
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

  Assert.isFalse(node.transZero)
  Assert.isFalse(node.rotZero)
  Assert.isFalse(node.scaleOne)
end

function T.rejects_malformed_node_data_offset()
  local m, err = Nsbmd.decode(Fixture.buildZeroNodeDataOffset())
  Assert.isNil(m)
  Assert.equal(assert(err).code, "NSBMD_NODE_DATA_OFFSET_ZERO")
end

function T.rejects_missing_mdl0()
  local bytes = NB.file("BMD0", { { magic = "TEX0", body = string.rep("\0", 60) } })
  local m, err = Nsbmd.decode(bytes)
  Assert.isNil(m)
  Assert.equal(assert(err).code, "NSBMD_NO_MDL0")
end

return { tests = T }
