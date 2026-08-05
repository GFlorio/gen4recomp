-- Decoder for placed-building records inside the HGSS land-data buildings
-- section. Each record is exactly 0x30 bytes: a building-model member id, an
-- fx position (signed integer + unsigned 1/65536 fraction per axis), three
-- packed rotation words (angle in the low 16 bits), three aligned fx32 scale
-- words, and reserved bytes preserved verbatim. Layout from the HGSS field
-- building-placement record. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local FixedPoint = require("libs.math.src.FixedPoint")

local BuildingPlacement = {}

local RECORD_SIZE = 0x30
local TWO_PI = 2 * math.pi

local function s16(reader, offset)
  local v = reader:u16le(offset)
  if v >= 0x8000 then return v - 0x10000 end
  return v
end

-- Angle stored in the low 16 bits of a 32-bit word -> radians.
local function angle(word)
  return (word % 0x10000) * TWO_PI / 65536
end

-- Decode one record at byteOffset. Returns (placement, nextOffset). The index
-- is derived from the offset, so records must be contiguous and 0x30-aligned.
function BuildingPlacement.decode(bytes, byteOffset, context)
  assert(type(bytes) == "string", "BuildingPlacement.decode requires a string")
  assert(byteOffset % RECORD_SIZE == 0, "building record offset must be 0x30-aligned")
  local r = BinaryReader.new(bytes, "building-placement")

  local xFraction, xInteger = r:u16le(byteOffset + 0x04), s16(r, byteOffset + 0x06)
  local yFraction, yInteger = r:u16le(byteOffset + 0x08), s16(r, byteOffset + 0x0A)
  local zFraction, zInteger = r:u16le(byteOffset + 0x0C), s16(r, byteOffset + 0x0E)
  local rx, ry, rz = r:u32le(byteOffset + 0x10), r:u32le(byteOffset + 0x14), r:u32le(byteOffset + 0x18)

  local scaleRaw = {
    width = r:u32le(byteOffset + 0x1C),
    height = r:u32le(byteOffset + 0x20),
    length = r:u32le(byteOffset + 0x24),
  }

  local placement = {
    index = byteOffset / RECORD_SIZE,
    modelMemberId = r:u32le(byteOffset + 0x00),
    position = {
      x = xInteger + xFraction / 65536,
      y = yInteger + yFraction / 65536,
      z = zInteger + zFraction / 65536,
    },
    positionRaw = {
      xInteger = xInteger, xFraction = xFraction,
      yInteger = yInteger, yFraction = yFraction,
      zInteger = zInteger, zFraction = zFraction,
    },
    rotation = { x = angle(rx), y = angle(ry), z = angle(rz) },
    rotationRaw = { x = rx, y = ry, z = rz },
    scale = {
      width = FixedPoint.fx32(scaleRaw.width),
      height = FixedPoint.fx32(scaleRaw.height),
      length = FixedPoint.fx32(scaleRaw.length),
    },
    scaleRaw = scaleRaw,
    unknown = {
      tail = r:bytes(byteOffset + 0x28, 8),
    },
    source = context,
  }
  return placement, byteOffset + RECORD_SIZE
end

function BuildingPlacement.decodeAll(bytes, context)
  assert(type(bytes) == "string", "BuildingPlacement.decodeAll requires a string")
  if #bytes % RECORD_SIZE ~= 0 then
    return nil, Errors.new("BUILDING_BAD_SIZE",
      "buildings section length " .. #bytes .. " is not a multiple of " .. RECORD_SIZE,
      { size = #bytes, recordSize = RECORD_SIZE, source = context })
  end
  local placements = {}
  local offset = 0
  while offset < #bytes do
    placements[#placements + 1], offset = BuildingPlacement.decode(bytes, offset, context)
  end
  return placements
end

return BuildingPlacement
