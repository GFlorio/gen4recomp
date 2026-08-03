-- Private target test: New Bark Town (map 60) against a real HGSS dump. Proves
-- the shared resolution/container pipeline handles the shared EVERYWHERE matrix
-- and an outdoor area. Runs only via `--test-private`. Asserts Gate 1 and
-- Gate 2 for the outdoor target.

local Assert = require("tests.support.Assert")
local MapResolver = require("src.data.MapResolver")
local AreaData = require("src.data.AreaData")
local LandData = require("src.data.LandData")

local T = {}

local function resolve(romFs)
  return assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
end

-- Gate 1: locate cell (21,12) by map-header id in the 47x17 shared matrix.
function T.gate1_semantic_resolution(romFs)
  local r = resolve(romFs)
  Assert.equal(r.map.id, 60)
  Assert.equal(r.matrixMemberId, 0)
  Assert.equal(r.matrix.width, 47)
  Assert.equal(r.matrix.height, 17)
  Assert.equal(r.matrix.name, "map")
  Assert.equal(r.matrixX, 21)
  Assert.equal(r.matrixZ, 12)
  Assert.equal(r.matrixIndex, 585)
  Assert.equal(r.landDataMemberId, 0)
  Assert.equal(r.worldOriginX, 672)
  Assert.equal(r.worldOriginZ, 384)
end

-- Gate 2: outdoor area-data member.
function T.gate2_area_data(romFs)
  local r = resolve(romFs)
  local narc = assert(romFs:openNarc("area_data"))
  local area = assert(AreaData.decode(assert(narc:readMember(r.areaDataMemberId))))
  Assert.equal(area.buildingTexturePackId, 0)
  Assert.equal(area.mapTexturePackId, 2)
  Assert.equal(area.dynamicTextureType, 0)
  Assert.equal(area.areaType, "outdoor")
  Assert.equal(area.lightType, 1)
end

-- Gate 2: land-data container for the outdoor chunk.
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
  local modelIds = {}
  for _, b in ipairs(land.buildings) do modelIds[#modelIds + 1] = b.modelMemberId end
  print(string.format(
    "  [new_bark] land member %d: bgsPayload=%d permissions=0x%X buildings=%d(%d recs) model=%d bdhc=%d",
    r.landDataMemberId, #land.bgs.payload, land.sizes.permissions,
    land.sizes.buildings, #land.buildings, land.sizes.model, land.sizes.bdhc))
  print("  [new_bark] placed building model ids: " .. table.concat(modelIds, " "))
  print("  [new_bark] collision values: " .. table.concat(land.permissions:usedCollisionValues(), " "))
end

return T
