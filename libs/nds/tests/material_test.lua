-- Tests for generic NNS G3D material register unpacking, ownership, and
-- masked global/material register semantics.

local Assert = require("tests.support.Assert")
local Material = require("libs.nds.src.gx.Material")

local T = {}

-- Pack a 15-bit BGR555 triple.
local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

function T.unpacks_diff_amb()
  local diffuse = rgb555(31, 0, 0)
  local ambient = rgb555(0, 0, 31)
  local word = diffuse + 2 ^ 15 + ambient * 2 ^ 16 -- set-vertex-color bit set
  local d = Material.unpackDiffAmb(word)
  Assert.equal(d.diffuseRgb555, diffuse)
  Assert.equal(d.ambientRgb555, ambient)
  Assert.isTrue(d.setVertexColor)
end

function T.unpacks_spec_emi()
  local specular = rgb555(1, 2, 3)
  local emission = rgb555(4, 5, 6)
  local word = specular + emission * 2 ^ 16 -- shininess-table bit clear
  local s = Material.unpackSpecEmi(word)
  Assert.equal(s.specularRgb555, specular)
  Assert.equal(s.emissionRgb555, emission)
  Assert.isFalse(s.useShininessTable)
end

function T.decodes_ownership_flags()
  local flags = Material.FLAG.diffuse + Material.FLAG.vertexColor + Material.FLAG.shininess
  local owns = Material.ownership(flags)
  Assert.isTrue(owns.diffuse)
  Assert.isTrue(owns.vertexColor)
  Assert.isTrue(owns.shininess)
  Assert.isFalse(owns.ambient)
  Assert.isFalse(owns.specular)
  Assert.isFalse(owns.emission)
end

function T.merges_masked_register_bits()
  Assert.equal(Material.mergeMasked(0x0000FF00, 0x000000A5, 0xFFFFFFFF), 0x000000A5)
  Assert.equal(Material.mergeMasked(0x0000FF00, 0x000000A5, 0x0000000F), 0x0000FF05)
end

function T.resolve_merges_masked_registers()
  local raw = {
    name = "m",
    polyAttrRaw = 0x000000A5,
    polyAttrMask = 0xFFFFFFFF,
    texImageParamRaw = 0x00030000,
    texImageParamMask = 0xFFFFFFFF,
    flagsRaw = 0xFFFF,
    diffuseRgb555 = 10,
    ambientRgb555 = 20,
    specularRgb555 = 30,
    emissionRgb555 = 40,
    setVertexColor = false,
    useShininessTable = false,
  }
  local globals = { polyAttr = 0x0000FF00, texImageParam = 0xFFFFFFFF }
  local eff = Material.resolve(raw, globals, Material.ownership(0))
  -- Full material mask: effective equals the material word, globals do not leak.
  Assert.equal(eff.polyAttr, 0x000000A5)
  Assert.equal(eff.texImageParam, 0x00030000)
  -- A generic policy can select the external source while preserving the
  -- authored RGB555 values.
  Assert.equal(eff.colors.diffuse.source, "global")
  Assert.equal(eff.colors.diffuse.rgb555, 10)
  Assert.equal(eff.colors.emission.source, "global")
  Assert.equal(eff.colors.emission.rgb555, 40)
end

function T.resolve_honors_material_owned_channel()
  local raw = {
    name = "m",
    polyAttrRaw = 0,
    polyAttrMask = 0xFFFFFFFF,
    texImageParamRaw = 0,
    texImageParamMask = 0xFFFFFFFF,
    flagsRaw = Material.FLAG.vertexColor,
    diffuseRgb555 = 7,
    ambientRgb555 = 0,
    specularRgb555 = 0,
    emissionRgb555 = 0,
    setVertexColor = false,
    useShininessTable = false,
  }
  -- A policy that keeps diffuse ownership makes diffuse a material channel.
  local policy = Material.ownership(Material.FLAG.diffuse)
  local eff = Material.resolve(raw, { polyAttr = 0, texImageParam = 0 }, policy)
  Assert.equal(eff.colors.diffuse.source, "material")
  Assert.equal(eff.colors.diffuse.rgb555, 7)
end

return { tests = T }
