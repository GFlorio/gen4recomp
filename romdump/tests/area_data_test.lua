local Assert = require("tests.support.Assert")
local AreaData = require("romdump.src.digest.AreaData")

local T = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u8(v)
  return string.char(v % 256)
end

-- building, map, dynamic (u16le each), areaType, lightType (u8 each).
local function build(building, map, dynamic, areaType, lightType)
  return u16(building) .. u16(map) .. u16(dynamic) .. u8(areaType) .. u8(lightType)
end

function T.decodes_elms_lab_indoor()
  local a = assert(AreaData.decode(build(1, 25, 0xFFFF, 0, 0)))
  Assert.equal(a.buildingTexturePackId, 1)
  Assert.equal(a.mapTexturePackId, 25)
  Assert.equal(a.dynamicTextureType, 0xFFFF)
  Assert.equal(a.areaType, "indoor")
  Assert.equal(a.areaTypeRaw, 0)
  Assert.equal(a.lightTypeRaw, 0)
end

function T.decodes_new_bark_outdoor()
  local a = assert(AreaData.decode(build(0, 2, 0, 1, 1)))
  Assert.equal(a.buildingTexturePackId, 0)
  Assert.equal(a.mapTexturePackId, 2)
  Assert.equal(a.dynamicTextureType, 0)
  Assert.equal(a.areaType, "outdoor")
  Assert.equal(a.lightTypeRaw, 1)
end

function T.preserves_unknown_area_type()
  local a = assert(AreaData.decode(build(0, 0, 0, 2, 0)))
  Assert.equal(a.areaType, "unknown")
  Assert.equal(a.areaTypeRaw, 2)
end

function T.carries_source_context()
  local a = assert(AreaData.decode(build(0, 0, 0, 0, 0), { memberId = 25 }))
  Assert.equal(a.source.memberId, 25)
end

function T.rejects_wrong_length()
  local short, sErr = AreaData.decode(string.rep("\0", 7))
  Assert.isNil(short)
  Assert.equal(assert(sErr).code, "AREA_DATA_BAD_SIZE")
  local long = AreaData.decode(string.rep("\0", 9))
  Assert.isNil(long)
end

return T
