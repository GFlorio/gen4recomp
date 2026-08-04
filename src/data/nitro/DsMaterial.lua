-- Effective-state resolution for a parsed NSBMD material. Nsbmd exposes the exact
-- file words; this module resolves them against the field-global render state and
-- the HGSS field-model policy, without mutating the raw material. It reproduces
-- NitroSystem's global/material merge: for POLYGON_ATTR and TEXIMAGE_PARAM the
-- material value applies only where its mask bit is set, the field global governs
-- elsewhere; for the lighting color channels an ownership flag (NNSG3dMatFlag)
-- decides whether the material or the field profile supplies each color.
--
-- Field references: GBATEK "DS 3D" for DIF_AMB/SPE_EMI/POLYGON_ATTR packing;
-- NitroSDK res_struct.h NNSG3dMatFlag for the ownership bits; the HGSS field
-- initialization path (pret/pokeheartgold) for the field-model color policy.
-- Pure domain module; arithmetic only.

local DsMaterial = {}

-- NNSG3dMatFlag ownership bits (NitroSDK res_struct.h). Bits below EMISSION
-- describe texture-matrix/origWH state we do not resolve here.
local FLAG = {
  diffuse = 0x0040,
  ambient = 0x0080,
  vertexColor = 0x0100,
  specular = 0x0200,
  emission = 0x0400,
  shininess = 0x0800,
}

-- The HGSS field draws map/building models with a field-model material policy
-- that clears model ownership of the four lighting colors, so the field light
-- profile supplies them. Vertex-color and shininess ownership are left intact.
local FIELD_POLICY_CLEARS = FLAG.diffuse + FLAG.ambient + FLAG.specular + FLAG.emission -- 0x06C0

-- Field-global POLYGON_ATTR / TEXIMAGE_PARAM defaults active when the map is
-- drawn. Verified against Elm + New Bark: every field material carries
-- polyAttrMask 0x3F1FF8FF -- exactly the union of every field DsPolygonAttr reads
-- (only reserved bits 8-10/21-23/30-31 fall through) -- and texImageParamMask
-- 0xFFFFFFFF. So no meaningful bit is governed by these globals; the zero values
-- are stated explicitly rather than assumed, and resolve() asserts the material
-- owns every decoded field to catch a future exception.
local HGSS_FIELD_DEFAULTS = {
  polyAttr = 0,
  texImageParam = 0,
}

-- Union of the POLYGON_ATTR bits DsPolygonAttr decodes: lightMask(0-3),
-- mode(4-5), render(6-7), flags(11-15), alpha(16-20), polygonId(24-29).
local MEANINGFUL_POLYATTR = 0x3F1FF8FF
-- texImageParam wrap S/T (16-17) and flip S/T (18-19), read for material wrap.
local MEANINGFUL_TEXPARAM = 0x000F0000

local function bit(word, i) return math.floor(word / 2 ^ i) % 2 == 1 end
local function rgb555(word) return word % 0x8000 end

-- DIF_AMB (GX 0x30): diffuse 0-14, set-vertex-color bit 15, ambient 16-30.
function DsMaterial.unpackDiffAmb(word)
  return {
    diffuseRgb555 = rgb555(word),
    setVertexColor = bit(word, 15),
    ambientRgb555 = rgb555(math.floor(word / 0x10000)),
  }
end

-- SPE_EMI (GX 0x31): specular 0-14, use-shininess-table bit 15, emission 16-30.
function DsMaterial.unpackSpecEmi(word)
  return {
    specularRgb555 = rgb555(word),
    useShininessTable = bit(word, 15),
    emissionRgb555 = rgb555(math.floor(word / 0x10000)),
  }
end

-- Decode the NNSG3dMatFlag ownership word into per-channel booleans.
function DsMaterial.ownership(flags)
  return {
    diffuse = bit(flags, 6),
    ambient = bit(flags, 7),
    vertexColor = bit(flags, 8),
    specular = bit(flags, 9),
    emission = bit(flags, 10),
    shininess = bit(flags, 11),
  }
end

-- The field-model ownership after the HGSS field policy clears the four color
-- bits. Returns a fresh ownership table; does not touch the raw material.
function DsMaterial.applyFieldPolicy(rawMaterial)
  local owns = DsMaterial.ownership(rawMaterial.flagsRaw)
  owns.diffuse = false
  owns.ambient = false
  owns.specular = false
  owns.emission = false
  return owns
end

-- Merge a masked register: material bits where the mask is set, global elsewhere.
local function merge(globalWord, materialWord, mask)
  -- (global & ~mask) | (material & mask), done arithmetically per bit.
  local out = 0
  for i = 0, 31 do
    local source = bit(mask, i) and materialWord or globalWord
    if bit(source, i) then out = out + 2 ^ i end
  end
  return out
end

-- True iff `mask` sets every bit in `required` (material owns all those fields).
local function owns(mask, required)
  for i = 0, 31 do
    if bit(required, i) and not bit(mask, i) then return false end
  end
  return true
end

-- Resolve a raw material against explicit field globals and an ownership policy.
-- globalState: { polyAttr, texImageParam }. policy: an ownership table (e.g. the
-- result of applyFieldPolicy) selecting which color channels the material owns.
-- Returns effective register words plus per-channel color sources; the material
-- RGB555 is retained even for channels the field currently owns.
function DsMaterial.resolve(rawMaterial, globalState, policy)
  assert(type(globalState) == "table", "resolve requires a globalState")
  assert(type(policy) == "table", "resolve requires an ownership policy")
  -- Every field DsPolygonAttr reads, and the wrap/flip bits, must be material-
  -- owned so the (unverified) field globals cannot surface in the decoded state.
  assert(owns(rawMaterial.polyAttrMask, MEANINGFUL_POLYATTR),
    "material " .. tostring(rawMaterial.name)
      .. " leaves meaningful polyAttr bits to the field global (unverified)")
  assert(owns(rawMaterial.texImageParamMask, MEANINGFUL_TEXPARAM),
    "material " .. tostring(rawMaterial.name)
      .. " leaves wrap/flip bits to the field global (unverified)")

  local function channel(owned, rgb555Value)
    return { source = owned and "material" or "field", rgb555 = rgb555Value }
  end

  return {
    polyAttr = merge(globalState.polyAttr, rawMaterial.polyAttrRaw, rawMaterial.polyAttrMask),
    texImageParam = merge(globalState.texImageParam, rawMaterial.texImageParamRaw, rawMaterial.texImageParamMask),
    colors = {
      diffuse = channel(policy.diffuse, rawMaterial.diffuseRgb555),
      ambient = channel(policy.ambient, rawMaterial.ambientRgb555),
      specular = channel(policy.specular, rawMaterial.specularRgb555),
      emission = channel(policy.emission, rawMaterial.emissionRgb555),
    },
    setVertexColor = rawMaterial.setVertexColor,
    useShininessTable = rawMaterial.useShininessTable,
  }
end

DsMaterial.FLAG = FLAG
DsMaterial.FIELD_POLICY_CLEARS = FIELD_POLICY_CLEARS
DsMaterial.HGSS_FIELD_DEFAULTS = HGSS_FIELD_DEFAULTS

return DsMaterial
