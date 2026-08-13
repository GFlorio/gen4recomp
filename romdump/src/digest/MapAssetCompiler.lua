-- Orchestrates the full derived-map compile for one semantic map: resolve the
-- target, decode its area/land/model/texture members, compile the map geometry
-- and every unique placed-building model into normalized batches and
-- content-addressed textures, and assemble a serializable bundle -- the scene
-- descriptor, the raw permission grid, the keyed mesh/texture blobs, the model
-- descriptors, and a dependency record hashed into a completion marker. It
-- writes nothing; MapCacheWriter persists the bundle. Runs under LÖVE (needs an
-- open RomFs) but the raw Nitro formats stop here.

local MapResolver = require("romdump.src.digest.MapResolver")
local AreaData = require("romdump.src.digest.AreaData")
local LandData = require("romdump.src.digest.LandData")
local HgssBdhc = require("romdump.src.digest.HgssBdhc")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local HgssFieldLighting = require("romdump.src.digest.HgssFieldLighting")
local HgssFieldLightProfile = require("romdump.src.digest.HgssFieldLightProfile")
local BuildingTransform = require("romdump.src.digest.BuildingTransform")
local MapUnits = require("romdump.src.digest.MapUnits")
local Hashing = require("romdump.src.digest.Hashing")
local Matrix4 = require("libs.math.src.Matrix4")
local VertexFormat = require("libs.assets.src.VertexFormat")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local NeighborPlan = require("romdump.src.digest.NeighborPlan")
local ModelAssetCompiler = require("romdump.src.digest.ModelAssetCompiler")
local NeighborChunkCompiler = require("romdump.src.digest.NeighborChunkCompiler")
local Errors = require("libs.errors.src.Errors")

local MapAssetCompiler = {}

local COORDINATE_CONVENTION = "nsbmd-sbc-matrix-16-tile-v3"

local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(
    memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count)
  )
  return assert(narc:readMember(memberId))
end

local function sortedNumbers(set)
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local function archiveForArea(area)
  if area.areaType == "indoor" then
    return "interior_build_models"
  end
  if area.areaType == "outdoor" then
    return "exterior_build_models"
  end
  Errors.raise(
    "MAP_COMPILE_UNSUPPORTED_AREA",
    "unsupported area type for building model selection: " .. tostring(area.areaTypeRaw),
    { areaTypeRaw = area.areaTypeRaw }
  )
end

local function _compile(romFs, idOrSymbol)
  local resolved = assert(MapResolver.resolve(romFs, idOrSymbol))
  local mapId = resolved.map.id
  local romSha1 = romFs:metadata().sha1

  -- Source members.
  local matrixNarc = assert(romFs:openNarc("map_matrices"))
  local matrixBytes = readMember(matrixNarc, "map_matrices", resolved.matrixMemberId)

  local areaNarc = assert(romFs:openNarc("area_data"))
  local areaBytes = readMember(areaNarc, "area_data", resolved.areaDataMemberId)
  local area = assert(AreaData.decode(areaBytes, { alias = "area_data", memberId = resolved.areaDataMemberId }))

  local landNarc = assert(romFs:openNarc("land_data"))
  local landBytes = readMember(landNarc, "land_data", resolved.landDataMemberId)
  local land =
    assert(LandData.decode(landBytes, { mapId = mapId, alias = "land_data", memberId = resolved.landDataMemberId }))
  local decodedTerrain = assert(HgssBdhc.decode(land.bdhcBytes, {
    mapId = mapId,
    alias = "land_data",
    memberId = resolved.landDataMemberId,
    offset = land.offsets.bdhc,
    size = land.sizes.bdhc,
  }))
  local bdhcSha1 = Hashing.sha1hex(land.bdhcBytes)
  local terrain = {
    schema = MapAssetCache.TERRAIN_SCHEMA,
    sourceFormat = decodedTerrain.schema,
    source = {
      landDataMemberId = resolved.landDataMemberId,
      bdhcOffset = land.offsets.bdhc,
      bdhcSize = land.sizes.bdhc,
      bdhcSha1 = bdhcSha1,
    },
    counts = decodedTerrain.counts,
    points = decodedTerrain.points,
    slopes = decodedTerrain.slopes,
    heights = decodedTerrain.heights,
    plates = decodedTerrain.plates,
    strips = decodedTerrain.strips,
    accessEntries = decodedTerrain.accessEntries,
  }

  -- Map model + calibration.
  local mapNsbmd = assert(
    Nsbmd.decode(
      land.mapModelBytes,
      { alias = "land_data", memberId = resolved.landDataMemberId, section = "map-model" }
    )
  )
  local mapModel = mapNsbmd.models[1]
  local exTiles, ezTiles = MapUnits.assertMapCalibration(mapModel.bounds, mapModel.info.posScale, { map = mapId })

  -- Map texture pack.
  local mapTexNarc = assert(romFs:openNarc("map_textures"))
  local mapTexBytes = readMember(mapTexNarc, "map_textures", area.mapTexturePackId)
  local mapTexPack = assert(Nsbtx.decode(mapTexBytes, { alias = "map_textures", memberId = area.mapTexturePackId }))

  -- Field-light profile selected by the area's raw light type.
  local selectedLight = HgssFieldLighting.resolve(area.lightTypeRaw, false)
  local lightBytes =
    assert(romFs:readSourcePath(selectedLight.sourcePath), "missing field-light profile: " .. selectedLight.sourcePath)
  local lightProfile = assert(HgssFieldLightProfile.parse(lightBytes, { sourcePath = selectedLight.sourcePath }))
  local lightSha1 = Hashing.sha1hex(lightBytes)

  local meshes, textures = {}, {}
  local mapCompiled = ModelAssetCompiler.compileModel(mapModel, mapTexPack, meshes, textures, {
    mapId = mapId,
    mapSymbol = resolved.map.symbol,
    role = "map",
    areaDataMemberId = resolved.areaDataMemberId,
    landDataMemberId = resolved.landDataMemberId,
    textureArchive = "map_textures",
    textureMemberId = area.mapTexturePackId,
    modelArchive = "land_data",
    modelMemberId = resolved.landDataMemberId,
    modelName = mapModel.name,
  })

  -- Materials whose names the pack they bind to does not define. They draw
  -- untextured, exactly as on the DS, so they are reported rather than fatal.
  local unresolvedMaterials = {}
  local function collectUnresolved(compiled)
    for _, entry in ipairs(compiled.unresolved) do
      unresolvedMaterials[#unresolvedMaterials + 1] = entry
    end
  end
  collectUnresolved(mapCompiled)

  -- Placed-building models (deduped by member id). HGSS binds each ordinary
  -- placed model to the area's external building texture pack and never uploads
  -- the model's own embedded TEX0 (pret/pokeheartgold `AreaDataManager_Load`);
  -- an embedded block present here is diagnostic only.
  local archiveAlias = archiveForArea(area)
  local uniqueMembers, placementIndicesByMember = {}, {}
  for _, pl in ipairs(land.buildings) do
    uniqueMembers[pl.modelMemberId] = true
    local indices = placementIndicesByMember[pl.modelMemberId] or {}
    indices[#indices + 1] = pl.index
    placementIndicesByMember[pl.modelMemberId] = indices
  end
  local memberIds = sortedNumbers(uniqueMembers)

  -- An area with no placed buildings points buildingTexturePackId at one of the
  -- four-byte placeholder members of building_textures, so the pack is loaded
  -- only when there is a model to bind -- as in the game, which has no models to
  -- pass to GF3dRender_BindModelSet either.
  local bldNarc, bldTexBytes, bldTexPack
  if #memberIds > 0 then
    bldNarc = assert(romFs:openNarc(archiveAlias))
    bldTexBytes =
      readMember(assert(romFs:openNarc("building_textures")), "building_textures", area.buildingTexturePackId)
    bldTexPack =
      assert(Nsbtx.decode(bldTexBytes, { alias = "building_textures", memberId = area.buildingTexturePackId }))
  end

  local models, modelKeyOf, memberShaOf = {}, {}, {}
  for _, memberId in ipairs(memberIds) do
    local mbytes = readMember(bldNarc, archiveAlias, memberId)
    local msha = Hashing.sha1hex(mbytes)
    local bnsbmd = assert(Nsbmd.decode(mbytes, { alias = archiveAlias, memberId = memberId }))
    local bmodel = bnsbmd.models[1]
    local compiled = ModelAssetCompiler.compileModel(bmodel, bldTexPack, meshes, textures, {
      mapId = mapId,
      mapSymbol = resolved.map.symbol,
      role = "building",
      areaDataMemberId = resolved.areaDataMemberId,
      landDataMemberId = resolved.landDataMemberId,
      textureArchive = "building_textures",
      textureMemberId = area.buildingTexturePackId,
      modelArchive = archiveAlias,
      modelMemberId = memberId,
      modelName = bmodel.name,
      embeddedTex0Present = bnsbmd.embeddedTextures ~= nil,
      placementIndices = placementIndicesByMember[memberId],
    })
    collectUnresolved(compiled)
    local modelKey =
      string.format("%s:%d:%s", area.areaType == "indoor" and "indoor" or "outdoor", memberId, msha:sub(1, 12))
    models[modelKey] =
      { key = modelKey, memberId = memberId, batches = compiled.batches, materials = compiled.materials }
    modelKeyOf[memberId] = modelKey
    memberShaOf[memberId] = msha
  end

  -- Building instances.
  local buildingInstances = {}
  for _, pl in ipairs(land.buildings) do
    local transform = BuildingTransform.build(pl)
    buildingInstances[#buildingInstances + 1] = {
      placementIndex = pl.index,
      modelKey = modelKeyOf[pl.modelMemberId],
      transform = Matrix4.toArray(transform),
    }
  end

  -- Plan the eight surrounding matrix cells and compile each unique land chunk
  -- once. Geometry/textures feed the draw ring; permission and BDHC artifacts
  -- make the same cells traversable in the field runtime.
  local plan = NeighborPlan.plan(resolved.matrix, resolved.matrixX, resolved.matrixZ, function(h)
    local rec = MapCatalog.areaForMapHeader(h)
    return rec and rec.areaDataMemberId or nil
  end)

  local neighborChunkByMember = {}
  for _, member in ipairs(plan.uniqueLandMembers) do
    local neighborCells, memberAreaId = {}, nil
    for _, cell in ipairs(plan.cells) do
      if cell.landDataMemberId == member then
        neighborCells[#neighborCells + 1] = { x = cell.x, z = cell.z }
        memberAreaId = memberAreaId or cell.areaDataMemberId
      end
    end
    local chunk = NeighborChunkCompiler.compile(romFs, member, memberAreaId, {
      mapId = mapId,
      mapSymbol = resolved.map.symbol,
      neighborCells = neighborCells,
    })
    for sha1, b in pairs(chunk.meshes) do
      meshes[sha1] = b
    end
    for sha1, t in pairs(chunk.textures) do
      textures[sha1] = t
    end
    collectUnresolved(chunk)
    neighborChunkByMember[member] = chunk
  end

  local neighbors = {}
  for _, cell in ipairs(plan.cells) do
    local chunk = neighborChunkByMember[cell.landDataMemberId]
    neighbors[#neighbors + 1] = {
      mapHeaderId = cell.mapHeaderId,
      landDataMemberId = cell.landDataMemberId,
      offsetTilesX = cell.offsetTilesX,
      offsetTilesZ = cell.offsetTilesZ,
      batches = chunk.batches,
      materials = chunk.materials,
      collision = {
        width = 32,
        height = 32,
        file = MapAssetCache.neighborCollisionPath(mapId, cell.landDataMemberId),
      },
      terrain = {
        schema = chunk.terrain.schema,
        file = MapAssetCache.neighborTerrainPath(mapId, cell.landDataMemberId),
      },
    }
  end

  -- Dependency record -> hash -> marker.
  local buildingModelShas = {}
  for _, memberId in ipairs(memberIds) do
    buildingModelShas[#buildingModelShas + 1] = { memberId = memberId, sha1 = memberShaOf[memberId] }
  end
  local dependencies = {
    cacheFormat = MapAssetCache.FORMAT,
    sceneSchemaVersion = MapAssetCache.SCENE_SCHEMA,
    coordinateConventionVersion = COORDINATE_CONVENTION,
    vertexFormatVersion = VertexFormat.VERSION,
    fieldLightSourcePath = selectedLight.sourcePath,
    fieldLightSourceSha1 = lightSha1,
    versionRomSha1 = romSha1,
    mapCatalogRecord = resolved.map,
    matrixMemberSha1 = Hashing.sha1hex(matrixBytes),
    areaDataMemberSha1 = Hashing.sha1hex(areaBytes),
    landDataMemberSha1 = Hashing.sha1hex(landBytes),
    terrainSchemaVersion = terrain.schema,
    bdhcSha1 = bdhcSha1,
    mapTextureMemberSha1 = Hashing.sha1hex(mapTexBytes),
    buildingArchive = archiveAlias,
    buildingTextureMemberId = bldTexBytes and area.buildingTexturePackId or nil,
    buildingTextureMemberSha1 = bldTexBytes and Hashing.sha1hex(bldTexBytes) or nil,
    uniqueBuildingModelMemberSha1s = buildingModelShas,
    -- Source-only facts about the compiled cell: matrix and area member
    -- identity, the matrix cell index/altitude, and the raw area record
    -- fields. None of these have a runtime consumer; they live on the
    -- producer dependency record, never in the runtime scene.
    matrix = {
      memberId = resolved.matrixMemberId,
      name = resolved.matrix.name,
      index = resolved.matrixIndex,
      altitude = resolved.matrixAltitude,
    },
    area = {
      memberId = resolved.areaDataMemberId,
      type = area.areaType,
      mapTexturePackId = area.mapTexturePackId,
      buildingTexturePackId = area.buildingTexturePackId,
      dynamicTextureType = area.dynamicTextureType,
      lightType = area.lightTypeRaw,
    },
  }
  local marker = MapAssetCache.marker(romSha1, mapId, Hashing.hashLua(dependencies))

  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = romFs:version(),
    mapId = mapId,
    mapSymbol = resolved.map.symbol,
    matrix = {
      width = resolved.matrix.width,
      height = resolved.matrix.height,
      x = resolved.matrixX,
      z = resolved.matrixZ,
      worldOriginX = resolved.worldOriginX,
      worldOriginZ = resolved.worldOriginZ,
    },
    cameraType = resolved.map.cameraType,
    collision = {
      width = 32,
      height = 32,
      file = MapAssetCache.collisionPath(mapId),
    },
    terrain = {
      schema = terrain.schema,
      file = MapAssetCache.terrainPath(mapId),
    },
    mapBatches = mapCompiled.batches,
    materials = mapCompiled.materials,
    buildingInstances = buildingInstances,
    neighbors = neighbors,
    calibration = { modelExtentTilesX = exTiles, modelExtentTilesZ = ezTiles, posScale = mapModel.info.posScale },
    limitations = {
      dynamicTexturesStatic = true,
    },
    -- The runtime consumes only the normalized records for time-of-day
    -- selection; the source light type, profile id, source path, and source
    -- hash are producer provenance and live in the dependency record.
    lighting = {
      records = lightProfile.records,
    },
  }

  return {
    mapId = mapId,
    marker = marker,
    scene = scene,
    dependencies = dependencies,
    collision = land.collision,
    terrain = terrain,
    neighborChunks = neighborChunkByMember,
    meshes = meshes,
    textures = textures,
    models = models,
    unresolvedMaterials = unresolvedMaterials,
  }
end

function MapAssetCompiler.compile(romFs, idOrSymbol)
  assert(romFs and romFs.openNarc, "compile requires a RomFs-shaped object")
  local ok, result = pcall(_compile, romFs, idOrSymbol)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return MapAssetCompiler
