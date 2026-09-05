-- HGSS field material policy layered on generic NNS G3D material semantics.
--
-- Field references: the HGSS field initialization path (pret/pokeheartgold)
-- for the field-model color policy and GBATEK "DS 3D" for register fields.

local Material = require("libs.nds.src.gx.Material")

local HgssFieldMaterial = {}

-- The HGSS field draws map/building models with a field-model material policy
-- that clears model ownership of the four lighting colors, so the field light
-- profile supplies them. Vertex-color and shininess ownership are left intact.
local FIELD_POLICY_CLEARS = Material.FLAG.diffuse
  + Material.FLAG.ambient
  + Material.FLAG.specular
  + Material.FLAG.emission

-- Field-global POLYGON_ATTR / TEXIMAGE_PARAM defaults active when the map is
-- drawn. The field corpus proves that all meaningful material fields are
-- owned; these zero defaults are retained for the masked-register contract.
local HGSS_FIELD_DEFAULTS = {
  polyAttr = 0,
  texImageParam = 0,
}

-- Union of the POLYGON_ATTR bits DsPolygonAttr decodes: lightMask(0-3),
-- mode(4-5), render(6-7), flags(11-15), alpha(16-20), polygonId(24-29).
local MEANINGFUL_POLYATTR = 0x3F1FF8FF
-- TEXIMAGE_PARAM wrap S/T (16-17) and flip S/T (18-19), read for material wrap.
local MEANINGFUL_TEXPARAM = 0x000F0000

-- The field-model ownership after the HGSS field policy clears the four color
-- bits. Returns a fresh ownership table; it does not touch the raw material.
function HgssFieldMaterial.applyFieldPolicy(rawMaterial)
  local owns = Material.ownership(rawMaterial.flagsRaw)
  owns.diffuse = false
  owns.ambient = false
  owns.specular = false
  owns.emission = false
  return owns
end

-- Resolve a raw field material against the current HGSS field defaults and
-- ownership policy. Corpus assertions remain at this producer boundary.
function HgssFieldMaterial.resolve(rawMaterial)
  assert(
    Material.ownsMask(rawMaterial.polyAttrMask, MEANINGFUL_POLYATTR),
    "material " .. tostring(rawMaterial.name) .. " leaves meaningful polyAttr bits to the field global (unverified)"
  )
  assert(
    Material.ownsMask(rawMaterial.texImageParamMask, MEANINGFUL_TEXPARAM),
    "material " .. tostring(rawMaterial.name) .. " leaves wrap/flip bits to the field global (unverified)"
  )
  local resolved = Material.resolve(rawMaterial, HGSS_FIELD_DEFAULTS, HgssFieldMaterial.applyFieldPolicy(rawMaterial))
  for _, channel in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
    if resolved.colors[channel].source == "global" then
      resolved.colors[channel].source = "field"
    end
  end
  return resolved
end

HgssFieldMaterial.FIELD_POLICY_CLEARS = FIELD_POLICY_CLEARS
HgssFieldMaterial.HGSS_FIELD_DEFAULTS = HGSS_FIELD_DEFAULTS

return HgssFieldMaterial
