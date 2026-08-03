-- Private target test: Professor Elm's Lab 1F (map 61) against a real HGSS dump.
-- Each function receives the open RomFs. This module is NOT in the public
-- tests/run.lua suite; it runs only via `--test-private` where a dump exists,
-- and asserts the externally observable Gate 1 and Gate 2 conditions.

local Assert = require("tests.support.Assert")
local MapResolver = require("src.data.MapResolver")
local AreaData = require("src.data.AreaData")
local LandData = require("src.data.LandData")

local T = {}

local function resolve(romFs)
  return assert(MapResolver.resolve(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"))
end

-- Gate 1: semantic resolution through the catalog, matrix, and model grid.
function T.gate1_semantic_resolution(romFs)
  local r = resolve(romFs)
  Assert.equal(r.map.id, 61)
  Assert.equal(r.matrixMemberId, 100)
  Assert.equal(r.matrix.width, 1)
  Assert.equal(r.matrix.height, 1)
  Assert.equal(r.matrix.name, "m_labo01_")
  Assert.equal(r.matrixX, 0)
  Assert.equal(r.matrixZ, 0)
  Assert.equal(r.landDataMemberId, 244)
  Assert.equal(r.worldOriginX, 0)
  Assert.equal(r.worldOriginZ, 0)
end

-- Gate 2: area-data member is exactly 8 bytes and decodes to the indoor pack.
function T.gate2_area_data(romFs)
  local r = resolve(romFs)
  local narc = assert(romFs:openNarc("area_data"))
  local area = assert(AreaData.decode(assert(narc:readMember(r.areaDataMemberId))))
  Assert.equal(area.buildingTexturePackId, 1)
  Assert.equal(area.mapTexturePackId, 25)
  Assert.equal(area.dynamicTextureType, 0xFFFF)
  Assert.equal(area.areaType, "indoor")
  Assert.equal(area.lightType, 0)
end

-- Gate 2: land-data container boundaries, BGS, permissions, buildings, model,
-- BDHC.
function T.gate2_land_containers(romFs)
  local r = resolve(romFs)
  local narc = assert(romFs:openNarc("land_data"))
  local bytes = assert(narc:readMember(r.landDataMemberId))
  local land = assert(LandData.decode(bytes,
    { mapId = r.map.id, alias = "land_data", memberId = r.landDataMemberId }))
  Assert.equal(land.bgs.signature, 0x1234)
  Assert.equal(land.sizes.permissions, 0x800)
  Assert.equal(land.sizes.buildings % 0x30, 0)
  Assert.equal(land.mapModelBytes:sub(1, 4), "BMD0")
  Assert.notNil(land.bdhcBytes, "BDHC slice must be available as opaque bytes")
  Assert.notNil(land.permissions:get(0, 0))
  print(string.format(
    "  [elms_lab] land member %d: bgsPayload=%d permissions=0x%X buildings=%d(%d recs) model=%d bdhc=%d",
    r.landDataMemberId, #land.bgs.payload, land.sizes.permissions,
    land.sizes.buildings, #land.buildings, land.sizes.model, land.sizes.bdhc))
  print("  [elms_lab] collision values: " .. table.concat(land.permissions:usedCollisionValues(), " "))
end

return T
