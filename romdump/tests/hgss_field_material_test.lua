-- Tests for the HGSS field material policy layered over generic NNS material
-- semantics.

local Assert = require("tests.support.Assert")
local Material = require("libs.nds.src.gx.Material")
local HgssFieldMaterial = require("romdump.src.digest.field.HgssFieldMaterial")

local T = {}

function T.field_policy_clears_only_the_four_colors()
  Assert.equal(HgssFieldMaterial.FIELD_POLICY_CLEARS, 0x06C0)
  local owns = HgssFieldMaterial.applyFieldPolicy({ flagsRaw = 0xFFFF })
  Assert.isFalse(owns.diffuse)
  Assert.isFalse(owns.ambient)
  Assert.isFalse(owns.specular)
  Assert.isFalse(owns.emission)
  Assert.isTrue(owns.vertexColor)
  Assert.isTrue(owns.shininess)
end

function T.field_resolution_preserves_defaults_and_ownership()
  local raw = {
    name = "field-material",
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
  local effective = HgssFieldMaterial.resolve(raw)
  Assert.equal(effective.polyAttr, raw.polyAttrRaw)
  Assert.equal(effective.texImageParam, raw.texImageParamRaw)
  Assert.equal(effective.colors.diffuse.source, "field")
  Assert.equal(effective.colors.emission.source, "field")
  Assert.equal(effective.colors.diffuse.rgb555, raw.diffuseRgb555)
end

function T.field_resolution_rejects_unverified_register_globals()
  local raw = {
    name = "unverified",
    polyAttrRaw = 0,
    polyAttrMask = 0x0000FFFF,
    texImageParamRaw = 0,
    texImageParamMask = 0xFFFFFFFF,
    flagsRaw = 0,
  }
  Assert.throws(function()
    HgssFieldMaterial.resolve(raw)
  end)
  Assert.isTrue(Material.ownsMask(raw.texImageParamMask, 0x000F0000))
end

return { tests = T }
