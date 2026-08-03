-- Private target test: New Bark Town (map 60) against a real HGSS dump. Proves
-- the shared resolution/container pipeline handles the shared EVERYWHERE matrix
-- and an outdoor area. Runs only via `--test-private`. Asserts Gate 1 and
-- Gate 2 for the outdoor target.

local Assert = require("tests.support.Assert")
local MapResolver = require("src.data.MapResolver")
local AreaData = require("src.data.AreaData")
local LandData = require("src.data.LandData")
local Nsbtx = require("src.data.nitro.Nsbtx")
local Nsbmd = require("src.data.nitro.Nsbmd")
local TextureDecoder = require("src.data.nitro.TextureDecoder")
local MapAssetInspector = require("src.import.MapAssetInspector")

local T = {}

local function resolve(romFs)
  return assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
end

local function isFinite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function assertTextureInventory(label, pack, packSize)
  Assert.isTrue(#pack.textures > 0, label .. ": pack has textures")
  for _, t in ipairs(pack.textures) do
    Assert.isTrue(TextureDecoder.SUPPORTED[t.formatRaw],
      label .. ": unsupported format " .. tostring(t.formatRaw) .. " for " .. t.name)
    Assert.isTrue(t.width >= 8 and t.height >= 8, label .. ": finite dimensions for " .. t.name)
    Assert.isTrue(t.dataAbsolute + t.dataSize <= packSize,
      label .. ": texel byte range in bounds for " .. t.name)
  end
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

-- Gate 3: the outdoor map/building texture packs inventory cleanly, including
-- the extra formats (A5I3/A3I5) not present in Elm's Lab.
function T.gate3_texture_inventory(romFs)
  local r = resolve(romFs)
  local area = assert(AreaData.decode(assert(romFs:openNarc("area_data")):readMember(r.areaDataMemberId)))

  local mapTexBytes = assert(romFs:openNarc("map_textures")):readMember(area.mapTexturePackId)
  assertTextureInventory("new_bark/map", assert(Nsbtx.decode(mapTexBytes)), #mapTexBytes)

  local bldTexBytes = assert(romFs:openNarc("building_textures")):readMember(area.buildingTexturePackId)
  assertTextureInventory("new_bark/building", assert(Nsbtx.decode(bldTexBytes)), #bldTexBytes)
end

-- Gate 4: the outdoor map model and exterior building models inventory with no
-- unsupported command, and the New Bark laboratory (BUILD_MODEL_WK_LABO,
-- member 21) resolves through the exterior archive.
function T.gate4_geometry_inventory(romFs)
  local r = resolve(romFs)
  local land = assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId),
    { mapId = r.map.id }))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  Assert.equal(model.info.numShp, 18)
  Assert.equal(#model.sbc.draws, 18)
  Assert.equal(model.sbc.opcodeCounts[0x01], 1) -- RET

  for _, shp in ipairs(model.shapes) do
    Assert.notNil(shp.bounds, "shape " .. shp.name .. " produced no geometry bounds")
    for k = 1, 3 do
      Assert.isTrue(isFinite(shp.bounds.min[k]) and isFinite(shp.bounds.max[k]),
        "non-finite bound in shape " .. shp.name)
    end
  end

  local report = assert(MapAssetInspector.inspect(romFs, "MAP_NEW_BARK"))
  Assert.equal(#report.warnings, 0)
  Assert.equal(report.buildings.archiveAlias, "exterior_build_models")

  -- Model 21 is present and identified as wk_labo (the laboratory exterior).
  local labo
  for _, s in ipairs(report.buildings.modelSummaries) do
    if s.memberId == 21 then labo = s end
  end
  Assert.notNil(labo, "New Bark should place exterior building model 21")
  Assert.equal(labo.modelName, "wk_labo")
  print(string.format("  [new_bark] map model %q: %d shapes, %d verts; lab exterior model 21 = %q",
    report.mapModel.modelName, report.mapModel.shapeCount, report.mapModel.vertexCount, labo.modelName))
end

return T
