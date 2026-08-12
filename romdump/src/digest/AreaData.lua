-- Decoder for an HGSS area-data member: an 8-byte record selecting the map and
-- building texture packs, the dynamic-texture animation type, and the
-- indoor/outdoor area type plus light type. The area type is the asset-level
-- source of truth for indoor vs outdoor building-model archive selection.
-- Layout recovered from pret/pokeheartgold field area-data handling.
-- Pure domain module; decode() returns (area | nil, err).

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local AreaData = {}

local AREA_TYPE = { [0] = "indoor", [1] = "outdoor" }
local SIZE = 8

local function parse(bytes, context)
  if #bytes ~= SIZE then
    Errors.raise(
      "AREA_DATA_BAD_SIZE",
      "HGSS area-data member must be " .. SIZE .. " bytes, got " .. #bytes,
      { size = #bytes, expected = SIZE, source = context }
    )
  end
  local r = BinaryReader.new(bytes, "area-data")
  local areaTypeRaw = r:u8(0x06)
  local lightTypeRaw = r:u8(0x07)
  return {
    buildingTexturePackId = r:u16le(0x00),
    mapTexturePackId = r:u16le(0x02),
    dynamicTextureType = r:u16le(0x04),
    areaType = AREA_TYPE[areaTypeRaw] or "unknown",
    areaTypeRaw = areaTypeRaw,
    -- Selects the HGSS field-light profile (see HgssFieldLighting). lightType is
    -- a transitional alias removed once every call site reads lightTypeRaw.
    lightTypeRaw = lightTypeRaw,
    lightType = lightTypeRaw,
    source = context,
  }
end

function AreaData.decode(bytes, context)
  assert(type(bytes) == "string", "AreaData.decode requires a string")
  local ok, result = pcall(parse, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return AreaData
