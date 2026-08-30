-- Decoder for a 32-bit DS POLYGON_ATTR word (GX command 0x29), following GBATEK
-- "GX POLYGON_ATTR - Set Polygon Attributes". A single geometry-engine register
-- carries the light-enable mask, polygon shading mode, front/back rendering,
-- several depth/fog flags, the 5-bit polygon alpha, and the 6-bit polygon id.
-- The effective value drawn for a shape is the global register default masked with
-- the material's owned bits; this module only unpacks a
-- resolved word into named fields. Pure domain module; arithmetic bit extraction.

local DsPolygonAttr = {}

-- 0=modulation, 1=decal, 2=toon/highlight, 3=shadow.
local POLYGON_MODES = { [0] = "modulation", [1] = "decal", [2] = "toon", [3] = "shadow" }

local function bit(word, i)
  return math.floor(word / 2 ^ i) % 2 == 1
end
local function field(word, shift, width)
  return math.floor(word / 2 ^ shift) % (2 ^ width)
end

-- Derive the love cull mode from the two surface-render flags. "all" is a
-- sentinel: the DS hides a polygon that renders neither surface, so the compiler
-- must skip such a batch rather than pass "all" to setMeshCullMode.
local function cullMode(renderFront, renderBack)
  if renderFront and renderBack then
    return "none"
  end
  if renderFront then
    return "back"
  end
  if renderBack then
    return "front"
  end
  return "all"
end

local CULL_MODES = { back = true, front = true, none = true }

-- Decode a resolved POLYGON_ATTR word into a normalized state record.
function DsPolygonAttr.decode(word)
  assert(type(word) == "number" and word >= 0 and word < 2 ^ 32, "POLYGON_ATTR must be a 32-bit word")
  local modeRaw = field(word, 4, 2)
  local renderBack = bit(word, 6)
  local renderFront = bit(word, 7)
  return {
    polygonAttrRaw = word,
    lightMask = field(word, 0, 4),
    polygonModeRaw = modeRaw,
    polygonMode = POLYGON_MODES[modeRaw],
    renderFront = renderFront,
    renderBack = renderBack,
    cullMode = cullMode(renderFront, renderBack),
    translucentDepthWrite = bit(word, 11),
    farClipEnabled = bit(word, 12),
    oneDotEnabled = bit(word, 13),
    depthEqual = bit(word, 14),
    fogEnabled = bit(word, 15),
    polygonAlpha = field(word, 16, 5),
    polygonId = field(word, 24, 6),
  }
end

DsPolygonAttr.POLYGON_MODES = POLYGON_MODES
DsPolygonAttr.CULL_MODES = CULL_MODES
DsPolygonAttr.LIGHT_MASK_MAX = 0x0F
DsPolygonAttr.POLYGON_ALPHA_MAX = 0x1F
DsPolygonAttr.POLYGON_ID_MAX = 0x3F

return DsPolygonAttr
