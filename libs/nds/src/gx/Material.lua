-- Generic NNS G3D material register and ownership semantics.
--
-- References: GBATEK "DS 3D" for DIF_AMB/SPE_EMI packing and NitroSDK
-- res_struct.h for NNSG3dMatFlag ownership bits. Product-specific field
-- defaults and ownership policy belong to the producer that supplies them.

local Material = {}

-- NNSG3dMatFlag ownership bits (NitroSDK res_struct.h). Bits below EMISSION
-- describe texture-matrix/origWH state that is not resolved here.
local FLAG = {
  diffuse = 0x0040,
  ambient = 0x0080,
  vertexColor = 0x0100,
  specular = 0x0200,
  emission = 0x0400,
  shininess = 0x0800,
}

local function bit(word, i)
  return math.floor(word / 2 ^ i) % 2 == 1
end

local function rgb555(word)
  return word % 0x8000
end

-- DIF_AMB (GX 0x30): diffuse 0-14, set-vertex-color bit 15, ambient 16-30.
function Material.unpackDiffAmb(word)
  return {
    diffuseRgb555 = rgb555(word),
    setVertexColor = bit(word, 15),
    ambientRgb555 = rgb555(math.floor(word / 0x10000)),
  }
end

-- SPE_EMI (GX 0x31): specular 0-14, use-shininess-table bit 15, emission 16-30.
function Material.unpackSpecEmi(word)
  return {
    specularRgb555 = rgb555(word),
    useShininessTable = bit(word, 15),
    emissionRgb555 = rgb555(math.floor(word / 0x10000)),
  }
end

-- Decode the NNSG3dMatFlag ownership word into per-channel booleans.
function Material.ownership(flags)
  return {
    diffuse = bit(flags, 6),
    ambient = bit(flags, 7),
    vertexColor = bit(flags, 8),
    specular = bit(flags, 9),
    emission = bit(flags, 10),
    shininess = bit(flags, 11),
  }
end

-- True when every bit in `required` is owned by the material mask.
function Material.ownsMask(mask, required)
  for i = 0, 31 do
    if bit(required, i) and not bit(mask, i) then
      return false
    end
  end
  return true
end

-- Merge a masked register: material bits where the mask is set, global
-- elsewhere. This is the generic NNS material/global register operation.
function Material.mergeMasked(globalWord, materialWord, mask)
  local out = 0
  for i = 0, 31 do
    local source = bit(mask, i) and materialWord or globalWord
    if bit(source, i) then
      out = out + 2 ^ i
    end
  end
  return out
end

-- Resolve a raw material against explicit global registers and an ownership
-- policy. The caller supplies any source-specific policy and validation.
function Material.resolve(rawMaterial, globalState, policy)
  assert(type(globalState) == "table", "resolve requires a globalState")
  assert(type(policy) == "table", "resolve requires an ownership policy")

  local function channel(owned, rgb555Value)
    return { source = owned and "material" or "global", rgb555 = rgb555Value }
  end

  return {
    polyAttr = Material.mergeMasked(globalState.polyAttr, rawMaterial.polyAttrRaw, rawMaterial.polyAttrMask),
    texImageParam = Material.mergeMasked(
      globalState.texImageParam,
      rawMaterial.texImageParamRaw,
      rawMaterial.texImageParamMask
    ),
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

Material.FLAG = FLAG

return Material
