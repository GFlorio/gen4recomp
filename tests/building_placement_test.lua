local Assert = require("tests.support.Assert")
local BuildingPlacement = require("src.data.BuildingPlacement")

local T = {}

local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- A single 0x30 record with distinctive values in every field.
local function record()
  return table.concat({
    u32(21),            -- 0x00 model member id
    u16(0x8000),        -- 0x04 X fraction (0.5)
    u16(5),             -- 0x06 X integer
    u16(0),             -- 0x08 Y fraction
    u16(0xFFFF),        -- 0x0A Y integer (-1 s16)
    u16(0x4000),        -- 0x0C Z fraction (0.25)
    u16(3),             -- 0x0E Z integer
    u32(0x4000),        -- 0x10 X rotation (low16 = 90 deg)
    u32(0x8000),        -- 0x14 Y rotation (low16 = 180 deg)
    u32(0xC000),        -- 0x18 Z rotation (low16 = 270 deg)
    string.char(0xAB),  -- 0x1C unknown byte
    u32(0x1000),        -- 0x1D width scale (unaligned)
    u32(0x2000),        -- 0x21 height scale
    u32(0x0800),        -- 0x25 length scale
    "\1\2\3\4\5\6\7",   -- 0x29 seven trailing bytes
  })
end

local function angle(low16) return low16 * 2 * math.pi / 65536 end

function T.decodes_all_fields_of_one_record()
  local p, nextOffset = BuildingPlacement.decode(record(), 0)
  Assert.equal(p.index, 0)
  Assert.equal(p.modelMemberId, 21)
  Assert.equal(nextOffset, 48)

  Assert.equal(p.position.x, 5.5)
  Assert.equal(p.position.y, -1)
  Assert.equal(p.position.z, 3.25)
  Assert.equal(p.positionRaw.xInteger, 5)
  Assert.equal(p.positionRaw.xFraction, 0x8000)
  Assert.equal(p.positionRaw.yInteger, -1)
  Assert.equal(p.positionRaw.zFraction, 0x4000)

  Assert.equal(p.rotation.x, angle(0x4000))
  Assert.equal(p.rotation.y, angle(0x8000))
  Assert.equal(p.rotation.z, angle(0xC000))
  Assert.equal(p.rotationRaw.x, 0x4000)
  Assert.equal(p.rotationRaw.y, 0x8000)
  Assert.equal(p.rotationRaw.z, 0xC000)

  Assert.equal(p.scaleRaw.width, 0x1000)
  Assert.equal(p.scaleRaw.height, 0x2000)
  Assert.equal(p.scaleRaw.length, 0x0800)

  Assert.equal(p.unknown.byte1C, 0xAB)
  Assert.equal(p.unknown.tail, "\1\2\3\4\5\6\7")
end

function T.decode_all_yields_sequential_indices()
  local placements = BuildingPlacement.decodeAll(record() .. record())
  Assert.equal(#placements, 2)
  Assert.equal(placements[1].index, 0)
  Assert.equal(placements[2].index, 1)
end

function T.decode_all_of_empty_section_is_empty()
  local placements = BuildingPlacement.decodeAll("")
  Assert.equal(#placements, 0)
end

function T.rejects_length_not_multiple_of_48()
  local placements, err = BuildingPlacement.decodeAll(record() .. "\0")
  Assert.isNil(placements)
  Assert.equal(err.code, "BUILDING_BAD_SIZE")
end

return T
