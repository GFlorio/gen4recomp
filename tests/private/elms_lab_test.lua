-- Private target test: Professor Elm's Lab 1F (map 61) against a real HGSS dump.
-- Each function receives the open RomFs. This module is NOT in the public
-- tests/run.lua suite; it runs only via `--test-private` where a dump exists,
-- and asserts the externally observable Gate 1 and Gate 2 conditions.

local Assert = require("tests.support.Assert")
local MapResolver = require("src.data.MapResolver")
local AreaData = require("src.data.AreaData")
local LandData = require("src.data.LandData")
local Nsbtx = require("src.data.nitro.Nsbtx")
local Nsbmd = require("src.data.nitro.Nsbmd")
local TextureDecoder = require("src.data.nitro.TextureDecoder")
local MapAssetInspector = require("src.import.MapAssetInspector")
local InventoryAssert = require("tests.support.InventoryAssert")
local CollisionGrid = require("src.world.CollisionGrid")
local DebugPlayer = require("src.world.DebugPlayer")
local TargetAnchors = require("data.manifests.target_map_anchors")

local T = {}

local function resolve(romFs)
  return assert(MapResolver.resolve(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"))
end

local function isFinite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Every texture must decode to a supported, finitely-dimensioned record with a
-- byte range inside the pack -- the observable Gate 3 texture inventory.
local function assertTextureInventory(label, pack, packSize)
  Assert.isTrue(#pack.textures > 0, label .. ": pack has textures")
  for _, t in ipairs(pack.textures) do
    Assert.isTrue(TextureDecoder.SUPPORTED[t.formatRaw],
      label .. ": unsupported format " .. tostring(t.formatRaw) .. " for " .. t.name)
    Assert.isTrue(t.width >= 8 and t.height >= 8, label .. ": finite dimensions for " .. t.name)
    Assert.isTrue(type(t.color0Transparent) == "boolean", label .. ": color0 flag for " .. t.name)
    Assert.isTrue(type(t.repeatX) == "boolean" and type(t.flipX) == "boolean",
      label .. ": wrap/flip flags for " .. t.name)
    Assert.isTrue(t.dataAbsolute + t.dataSize <= packSize,
      label .. ": texel byte range in bounds for " .. t.name)
  end
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
  -- Indoor chunk carries no BGS/soundplate payload, so permissions sit at 0x14.
  Assert.equal(#land.bgs.payload, 0)
  -- Observed permission bytes: only 0x80 hard-blocks; 0 and 6 are passable
  -- surface responses, not obstacles.
  Assert.deepEqual(land.permissions:usedPermissionValues(), { 0, 6, 128 })
  print(string.format(
    "  [elms_lab] land member %d: bgsPayload=%d permissions=0x%X buildings=%d(%d recs) model=%d bdhc=%d",
    r.landDataMemberId, #land.bgs.payload, land.sizes.permissions,
    land.sizes.buildings, #land.buildings, land.sizes.model, land.sizes.bdhc))
  print("  [elms_lab] permission values: " .. table.concat(land.permissions:usedPermissionValues(), " "))
end

-- Gate 3: the map and building texture packs inventory cleanly, and every
-- material name the map model references resolves to a real texture.
function T.gate3_texture_inventory(romFs)
  local r = resolve(romFs)
  local area = assert(AreaData.decode(assert(romFs:openNarc("area_data")):readMember(r.areaDataMemberId)))

  local mapTexBytes = assert(romFs:openNarc("map_textures")):readMember(area.mapTexturePackId)
  local mapPack = assert(Nsbtx.decode(mapTexBytes))
  assertTextureInventory("elms_lab/map", mapPack, #mapTexBytes)

  local bldTexBytes = assert(romFs:openNarc("building_textures")):readMember(area.buildingTexturePackId)
  local bldPack = assert(Nsbtx.decode(bldTexBytes))
  assertTextureInventory("elms_lab/building", bldPack, #bldTexBytes)

  -- Every texture the map model binds must exist in the map texture pack.
  local land = assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId),
    { mapId = r.map.id }))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  for _, assoc in ipairs(model.textureAssociations) do
    Assert.notNil(mapPack.textureByName[assoc.name],
      "map material texture missing from pack: " .. assoc.name)
  end
end

-- Gate 4: the map model inventories fully -- counts, SBC/GX opcode coverage,
-- material associations, and finite bounds for every shape batch -- with no
-- unsupported command in the Elm target set.
function T.gate4_geometry_inventory(romFs)
  local r = resolve(romFs)
  local land = assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId),
    { mapId = r.map.id }))
  local nsbmd = assert(Nsbmd.decode(land.mapModelBytes))
  Assert.equal(#nsbmd.models, 1)
  local model = nsbmd.models[1]
  Assert.equal(model.info.numNode, 1)
  Assert.equal(model.info.numMat, 10)
  Assert.equal(model.info.numShp, 10)
  Assert.equal(#model.shapes, 10)

  -- SBC pairs each shape with a material; RET terminates the stream.
  Assert.equal(#model.sbc.draws, 10)
  Assert.equal(model.sbc.opcodeCounts[0x05], 10) -- SHP
  Assert.equal(model.sbc.opcodeCounts[0x04], 10) -- MAT
  Assert.equal(model.sbc.opcodeCounts[0x01], 1) -- RET

  -- Finite bounds for every compiled mesh batch.
  for _, shp in ipairs(model.shapes) do
    Assert.notNil(shp.bounds, "shape " .. shp.name .. " produced no geometry bounds")
    for k = 1, 3 do
      Assert.isTrue(isFinite(shp.bounds.min[k]) and isFinite(shp.bounds.max[k]),
        "non-finite bound in shape " .. shp.name)
    end
    Assert.isTrue(shp.triangleCount > 0, "shape " .. shp.name .. " has no triangles")
  end

  -- 9 of 10 materials are textured (lambert1 is untextured); each textured
  -- material carries both a texture and a palette association.
  local textured = 0
  for _, mat in ipairs(model.materials) do
    if mat.textureName then
      textured = textured + 1
      Assert.notNil(mat.paletteName, "textured material lacks palette: " .. mat.name)
    end
  end
  Assert.equal(textured, 9)

  -- The inspector assembles the whole report with no warnings.
  local report = assert(MapAssetInspector.inspect(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"))
  Assert.equal(#report.warnings, 0)
  Assert.equal(report.buildings.archiveAlias, "interior_build_models")
  -- The material/polygon-state inventory is finite and fully supported.
  InventoryAssert.assertSupported(report.featureInventory, "elms_lab")
  for _, s in ipairs(report.buildings.modelSummaries) do
    Assert.notNil(s.bounds, "building model " .. s.memberId .. " produced no bounds")
  end
  print(string.format("  [elms_lab] map model %q: %d shapes, %d verts, %d placed building models",
    report.mapModel.modelName, report.mapModel.shapeCount, report.mapModel.vertexCount,
    #report.buildings.modelIds))
end

-- Gate 7: the debug player traverses the real permission grid tile-by-tile,
-- stays inside the 32x32 cell, is blocked only by the 0x80 hard-block bit
-- (responses 4/6 stay passable), and can stand at and around the exit warp.
function T.gate7_traversal(romFs)
  local r = resolve(romFs)
  local land = assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId),
    { mapId = r.map.id }))
  local grid = land.permissions
  local collision = CollisionGrid.new(grid, {
    worldOriginX = r.worldOriginX, worldOriginZ = r.worldOriginZ })

  -- Provisional spawn is in-bounds and passable (no relocation needed).
  local spawn = TargetAnchors.MAP_NEW_BARK_ELMS_LAB_1F.spawn
  local player = DebugPlayer.new(collision, spawn)
  local s = player:status()
  Assert.isFalse(s.spawnFallback)
  Assert.equal(s.localX, 4)
  Assert.equal(s.localZ, 13)
  Assert.isFalse(s.hardBlocked)

  -- The exit warp (4,14) is passable and one step south of the spawn.
  Assert.isFalse(collision:isBlockedLocal(4, 14))
  Assert.isTrue(player:tryStep("south"))
  Assert.equal(player:status().localZ, 14)

  -- Only the 0x80 bit blocks: the perimeter wall hard-blocks, interior floor
  -- (behavior 0 / response 6) does not.
  Assert.isTrue(grid:isBlocked(0, 0))
  Assert.isFalse(grid:isBlocked(4, 13))
  Assert.deepEqual(grid:usedPermissionValues(), { 0, 6, 128 })

  -- Movement respects a wall: stepping east into the (12,13) wall is refused but
  -- still turns the player, and never leaves the tile.
  local wallward = DebugPlayer.new(collision, { x = 11, z = 13 })
  Assert.isFalse(wallward:tryStep("east"))
  Assert.equal(wallward:status().localX, 11)
  Assert.equal(wallward:status().facing, "east")

  -- The 32x32 cell is a hard boundary: from passable edge tiles a step off the
  -- grid is refused without wrapping.
  local westEdge = DebugPlayer.new(collision, { x = 0, z = 16 })
  Assert.isFalse(westEdge.spawnFallback)
  Assert.isFalse(westEdge:tryStep("west"))
  local northEdge = DebugPlayer.new(collision, { x = 16, z = 0 })
  Assert.isFalse(northEdge.spawnFallback)
  Assert.isFalse(northEdge:tryStep("north"))
end

return T
