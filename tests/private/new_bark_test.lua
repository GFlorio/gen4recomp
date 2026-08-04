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
local InventoryAssert = require("tests.support.InventoryAssert")
local CacheFs = require("src.import.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCompiler = require("src.import.MapAssetCompiler")
local MapCacheWriter = require("src.import.MapCacheWriter")
local MapAssetCache = require("src.core.MapAssetCache")
local PermissionGrid = require("src.data.PermissionGrid")
local CollisionGrid = require("src.world.CollisionGrid")
local DebugPlayer = require("src.world.DebugPlayer")
local TargetAnchors = require("data.manifests.target_map_anchors")

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
  -- Outdoor chunk carries an 88-byte BGS/soundplate payload (excludes the
  -- 4-byte 0x1234+size header), pushing permissions to 0x14 + 88 = 0x6C.
  Assert.equal(#land.bgs.payload, 88)
  Assert.equal(land.offsets.permissions, 0x14 + 88)
  -- Observed permission bytes: only 0x80 hard-blocks; 0, 4, 6 are passable
  -- surface responses.
  Assert.deepEqual(land.permissions:usedPermissionValues(), { 0, 4, 6, 128 })
  local modelIds = {}
  for _, b in ipairs(land.buildings) do modelIds[#modelIds + 1] = b.modelMemberId end
  print(string.format(
    "  [new_bark] land member %d: bgsPayload=%d permissions=0x%X buildings=%d(%d recs) model=%d bdhc=%d",
    r.landDataMemberId, #land.bgs.payload, land.sizes.permissions,
    land.sizes.buildings, #land.buildings, land.sizes.model, land.sizes.bdhc))
  print("  [new_bark] placed building model ids: " .. table.concat(modelIds, " "))
  print("  [new_bark] permission values: " .. table.concat(land.permissions:usedPermissionValues(), " "))
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
  -- The material/polygon-state inventory is finite and fully supported, even
  -- with the outdoor a3i5/a5i3 textures and NORMAL-lit geometry.
  InventoryAssert.assertSupported(report.featureInventory, "new_bark")

  -- New Bark's outdoor area selects field-light profile 0 (area00light.txt).
  Assert.equal(report.lighting.lightTypeRaw, 1)
  Assert.equal(report.lighting.profileId, 0)
  Assert.equal(report.lighting.sourcePath, "data/area00light.txt")
  Assert.isTrue(report.lighting.recordCount > 0, "new bark profile has records")

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

-- Flower quads tile: their UVs run outside [0,1], so they only render if the
-- material programs repeat wrap. That wrap lives in each material's parsed
-- texImageParam (NNSG3dResMatData), not the NSBTX template (which reads clamp
-- for map textures). Guard both the parse and the compiled scene material.
function T.flowers_tile_via_material_wrap(romFs)
  local r = resolve(romFs)
  local land = assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId),
    { mapId = r.map.id }))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  for _, mat in ipairs(model.materials) do
    if mat.textureName and mat.textureName:find("^flower") then
      Assert.isTrue(mat.repeatX and mat.repeatY, mat.name .. " must request repeat wrap")
    end
  end

  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local flowerMat
  for _, m in ipairs(bundle.scene.materials) do
    if m.name:find("^flower") then flowerMat = m end
  end
  Assert.notNil(flowerMat, "scene carries a flower material")
  Assert.equal(flowerMat.wrap.x, "repeat")
  Assert.equal(flowerMat.wrap.y, "repeat")
end

-- Gate 9: New Bark's central cell compiles into a scene that carries all the
-- Phase B diagnostic display data (matrix 0 cell (21,12) index 585, land 0, area
-- 2, origin (672,384)), an outdoor map model with its map texture pack, the lab
-- exterior model 21 resolved through the outdoor archive, and a consistent lab-
-- entry anchor. The debug player spawns inside the local 32x32 cell.
function T.gate9_central_cell_scene(romFs, version)
  local c = CacheFs.forVersion(version, FakeCache.new())
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  MapCacheWriter.write(c, bundle)
  local scene = bundle.scene

  local m = scene.matrix
  Assert.equal(m.memberId, 0)
  Assert.equal(m.name, "map")
  Assert.equal(m.width, 47)
  Assert.equal(m.height, 17)
  Assert.equal(m.x, 21)
  Assert.equal(m.z, 12)
  Assert.equal(m.index, 585)
  Assert.equal(m.worldOriginX, 672)
  Assert.equal(m.worldOriginZ, 384)
  Assert.equal(scene.source.landData.memberId, 0)

  Assert.equal(scene.area.memberId, 2)
  Assert.equal(scene.area.type, "outdoor")
  Assert.equal(scene.area.mapTexturePackId, 2)
  Assert.equal(scene.area.buildingTexturePackId, 0)

  -- Outdoor map model with its texture pack is drawn, and the laboratory
  -- exterior (wk_labo, member 21) resolves through the outdoor archive.
  Assert.isTrue(#scene.mapBatches > 0, "outdoor map model has draw batches")
  local labo = false
  for _, inst in ipairs(scene.buildingInstances) do
    if inst.modelKey:find("^outdoor:21:") then labo = true end
  end
  Assert.isTrue(labo, "lab exterior model 21 placed via the outdoor archive")

  -- The lab-entry anchor is coordinate-consistent: local + cell origin == global.
  local anchor = TargetAnchors.MAP_NEW_BARK.anchors[1]
  Assert.equal(anchor.localX + m.worldOriginX, anchor.globalX)
  Assert.equal(anchor.localZ + m.worldOriginZ, anchor.globalZ)

  -- The debug player spawns inside the central 32x32 cell on a passable tile.
  local perms = assert(c:read(MapAssetCache.mapDir(60) .. "/permissions.bin"))
  local collision = CollisionGrid.new(assert(PermissionGrid.decode(perms)), {
    worldOriginX = m.worldOriginX, worldOriginZ = m.worldOriginZ })
  local player = DebugPlayer.new(collision, TargetAnchors.MAP_NEW_BARK.spawn)
  local s = player:status()
  Assert.isTrue(s.localX >= 0 and s.localX < 32 and s.localZ >= 0 and s.localZ < 32, "spawn in cell")
  Assert.isFalse(s.hardBlocked)
  Assert.equal(s.globalX, s.localX + 672)
  Assert.equal(s.globalZ, s.localZ + 384)
end

return T
