-- Orchestrates the full derived-map compile for one semantic map: resolve the
-- target, decode its area/land/model/texture members, compile the map geometry
-- and every unique placed-building model into normalized batches and
-- content-addressed textures, and assemble a serializable bundle -- the scene
-- descriptor, the raw permission grid, the keyed mesh/texture blobs, the model
-- descriptors, and a dependency record hashed into a completion marker. It
-- writes nothing; MapCacheWriter persists the bundle. Runs under LÖVE (needs an
-- open RomFs) but the raw Nitro formats stop here.

local MapResolver = require("libs.assets.src.MapResolver")
local AreaData = require("libs.assets.src.AreaData")
local LandData = require("libs.assets.src.LandData")
local Nsbmd = require("libs.assets.src.nitro.Nsbmd")
local Nsbtx = require("libs.assets.src.nitro.Nsbtx")
local MeshCompiler = require("libs.assets.src.MeshCompiler")
local MaterialCompiler = require("libs.assets.src.MaterialCompiler")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local DsPolygonAttr = require("libs.assets.src.nitro.DsPolygonAttr")
local HgssFieldLighting = require("libs.assets.src.HgssFieldLighting")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local BuildingTransform = require("libs.assets.src.BuildingTransform")
local MeshWriter = require("libs.assets.src.MeshWriter")
local MapUnits = require("libs.assets.src.MapUnits")
local Hashing = require("libs.assets.src.Hashing")
local Matrix4 = require("libs.math.src.Matrix4")
local VertexFormat = require("libs.assets.src.VertexFormat")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCatalog = require("libs.assets.src.MapCatalog")
local NeighborPlan = require("libs.assets.src.NeighborPlan")
local Errors = require("libs.rom.src.Errors")

local MapAssetCompiler = {}

local COMPILER_VERSION = "map-compiler-v7"
local COORDINATE_CONVENTION = "nsbmd-sbc-matrix-16-tile-v3"
local SCENE_SCHEMA = "g4-map-scene-v2"

local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count))
  return assert(narc:readMember(memberId))
end

local function sortedNumbers(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- Convert MaterialCompiler records (texture = sha1 key) into scene material
-- records (texture = cache-relative PNG path). Polygon state (alpha class,
-- cull mode, polygon alpha/mode) lives on the batch, not the material.
local function sceneMaterials(records)
  local out = {}
  for _, m in ipairs(records) do
    out[#out + 1] = {
      id = m.id,
      name = m.name,
      texture = m.texture and MapAssetCache.texturePath(m.texture) or nil,
      textureFormat = m.textureFormat,
      wrap = m.wrap,
      flip = m.flip,
      diffuse = m.diffuse,
    }
  end
  return out
end

-- Compile one model into batches; append meshes/textures to the shared bundle
-- accumulators; return { batches (scene refs), materials }.
local function compileModel(model, texturePack, meshes, textures, context)
  local mat = MaterialCompiler.compile(model.materials, texturePack, { context = context })
  for sha1, tex in pairs(mat.textures) do textures[sha1] = tex end

  -- Per-material texture info needed for batch classification and UV normalization.
  local matInfoById = {}
  for _, m in ipairs(mat.materials) do
    matInfoById[m.id] = {
      texWidth = m.texWidth,
      texHeight = m.texHeight,
      textureFormat = m.textureFormat or 0,
      alphaUsage = m.texture and textures[m.texture] and textures[m.texture].alphaUsage or nil,
    }
  end

  local batches = {}
  for _, batch in ipairs(MeshCompiler.compile(model)) do
    local info = matInfoById[batch.materialIndex]
    if info then
      if info.texWidth then
        for _, vtx in ipairs(batch.vertices) do
          vtx.u = vtx.u / info.texWidth
          vtx.v = vtx.v / info.texHeight
        end
      end
    end

    local poly = DsPolygonAttr.decode(batch.polygonAttrRaw)
    if poly.cullMode ~= "all" then
      local fmt = info and info.textureFormat or 0
      local alphaClass = AlphaClassifier.classify(poly.polygonAlpha, fmt,
        info and info.alphaUsage or nil)
      local sha1 = Hashing.sha1hex(MeshWriter.encode(batch))
      meshes[sha1] = batch
      batches[#batches + 1] = {
        geometry = MapAssetCache.geometryPath(sha1),
        material = batch.materialIndex,
        node = batch.nodeIndex,
        submissionIndex = batch.submissionIndex,
        alphaClass = alphaClass,
        cullMode = poly.cullMode,
        polygonAlpha = poly.polygonAlpha,
        polygonMode = poly.polygonMode,
        lightMask = poly.lightMask,
        polygonId = poly.polygonId,
        translucentDepthWrite = poly.translucentDepthWrite,
        depthEqual = poly.depthEqual,
        farClipEnabled = poly.farClipEnabled,
        oneDotEnabled = poly.oneDotEnabled,
        fogEnabled = poly.fogEnabled,
      }
    end
  end
  return { batches = batches, materials = sceneMaterials(mat.materials) }
end

local function archiveForArea(area)
  if area.areaType == "indoor" then return "interior_build_models" end
  if area.areaType == "outdoor" then return "exterior_build_models" end
  Errors.raise("MAP_COMPILE_UNSUPPORTED_AREA",
    "unsupported area type for building model selection: " .. tostring(area.areaTypeRaw),
    { areaTypeRaw = area.areaTypeRaw })
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
  local land = assert(LandData.decode(landBytes,
    { mapId = mapId, alias = "land_data", memberId = resolved.landDataMemberId }))

  -- Map model + calibration.
  local mapNsbmd = assert(Nsbmd.decode(land.mapModelBytes,
    { alias = "land_data", memberId = resolved.landDataMemberId, section = "map-model" }))
  local mapModel = mapNsbmd.models[1]
  local exTiles, ezTiles = MapUnits.assertMapCalibration(mapModel.bounds, mapModel.info.posScale, { map = mapId })

  -- Map texture pack.
  local mapTexNarc = assert(romFs:openNarc("map_textures"))
  local mapTexBytes = readMember(mapTexNarc, "map_textures", area.mapTexturePackId)
  local mapTexPack = assert(Nsbtx.decode(mapTexBytes,
    { alias = "map_textures", memberId = area.mapTexturePackId }))

  -- Field-light profile selected by the area's raw light type.
  local selectedLight = HgssFieldLighting.resolve(area.lightTypeRaw, false)
  local lightBytes = assert(romFs:readSourcePath(selectedLight.sourcePath),
    "missing field-light profile: " .. selectedLight.sourcePath)
  local lightProfile = assert(FieldLightProfile.parse(lightBytes,
    { sourcePath = selectedLight.sourcePath }))
  local lightSha1 = Hashing.sha1hex(lightBytes)

  local meshes, textures = {}, {}
  local mapCompiled = compileModel(mapModel, mapTexPack, meshes, textures,
    { model = "map", memberId = resolved.landDataMemberId })

  -- Placed-building models (deduped by member id).
  local archiveAlias = archiveForArea(area)
  local bldNarc = assert(romFs:openNarc(archiveAlias))
  local uniqueMembers = {}
  for _, pl in ipairs(land.buildings) do uniqueMembers[pl.modelMemberId] = true end

  local models, modelKeyOf, memberShaOf = {}, {}, {}
  for _, memberId in ipairs(sortedNumbers(uniqueMembers)) do
    local mbytes = readMember(bldNarc, archiveAlias, memberId)
    local msha = Hashing.sha1hex(mbytes)
    local bnsbmd = assert(Nsbmd.decode(mbytes, { alias = archiveAlias, memberId = memberId }))
    local bmodel = bnsbmd.models[1]
    -- Placed models carry their own textures via embedded TEX0.
    local texSource = bnsbmd.embeddedTextures
    if not texSource then
      Errors.raise("MAP_COMPILE_BUILDING_TEXTURES_UNRESOLVED",
        "building model " .. memberId .. " has no embedded textures and area-pack fallback is unimplemented",
        { memberId = memberId, archive = archiveAlias })
    end
    local compiled = compileModel(bmodel, texSource, meshes, textures,
      { model = archiveAlias, memberId = memberId })
    local modelKey = string.format("%s:%d:%s",
      area.areaType == "indoor" and "indoor" or "outdoor", memberId, msha:sub(1, 12))
    models[modelKey] = { key = modelKey, memberId = memberId,
      batches = compiled.batches, materials = compiled.materials }
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

  -- Presentation-only neighbour ring: plan the eight surrounding matrix cells,
  -- compile each unique land chunk once (terrain only) into the shared mesh/
  -- texture pools so its assets dedup, then emit one scene descriptor per drawn
  -- cell carrying its 32-tile offset and its land member's batches/materials.
  local NeighborChunkCompiler = require("libs.assets.src.NeighborChunkCompiler")
  local plan = NeighborPlan.plan(resolved.matrix, resolved.matrixX, resolved.matrixZ,
    function(h) local rec = MapCatalog.areaForMapHeader(h); return rec and rec.areaDataMemberId or nil end)

  local neighborChunkByMember = {}
  for _, member in ipairs(plan.uniqueLandMembers) do
    local memberAreaId
    for _, cell in ipairs(plan.cells) do
      if cell.landDataMemberId == member then memberAreaId = cell.areaDataMemberId break end
    end
    local chunk = NeighborChunkCompiler.compile(romFs, member, memberAreaId)
    for sha1, b in pairs(chunk.meshes) do meshes[sha1] = b end
    for sha1, t in pairs(chunk.textures) do textures[sha1] = t end
    neighborChunkByMember[member] = { batches = chunk.batches, materials = chunk.materials }
  end

  local neighbors = {}
  for _, cell in ipairs(plan.cells) do
    local chunk = neighborChunkByMember[cell.landDataMemberId]
    neighbors[#neighbors + 1] = {
      offsetTilesX = cell.offsetTilesX,
      offsetTilesZ = cell.offsetTilesZ,
      batches = chunk.batches,
      materials = chunk.materials,
    }
  end

  -- Dependency record -> hash -> marker.
  local buildingModelShas = {}
  for _, memberId in ipairs(sortedNumbers(uniqueMembers)) do
    buildingModelShas[#buildingModelShas + 1] = { memberId = memberId, sha1 = memberShaOf[memberId] }
  end
  local dependencies = {
    cacheFormat = MapAssetCache.FORMAT,
    compilerVersion = COMPILER_VERSION,
    sceneSchemaVersion = SCENE_SCHEMA,
    coordinateConventionVersion = COORDINATE_CONVENTION,
    textureDecoderVersion = MaterialCompiler.DECODER_VERSION,
    materialNormalizerVersion = AlphaClassifier.VERSION,
    vertexFormatVersion = VertexFormat.VERSION,
    fieldLightParserVersion = FieldLightProfile.VERSION,
    fieldLightSourcePath = selectedLight.sourcePath,
    fieldLightSourceSha1 = lightSha1,
    versionRomSha1 = romSha1,
    mapCatalogRecord = resolved.map,
    matrixMemberSha1 = Hashing.sha1hex(matrixBytes),
    areaDataMemberSha1 = Hashing.sha1hex(areaBytes),
    landDataMemberSha1 = Hashing.sha1hex(landBytes),
    mapTextureMemberSha1 = Hashing.sha1hex(mapTexBytes),
    buildingArchive = archiveAlias,
    uniqueBuildingModelMemberSha1s = buildingModelShas,
  }
  local marker = MapAssetCache.marker(romSha1, mapId, Hashing.hashLua(dependencies))

  local scene = {
    schema = SCENE_SCHEMA,
    versionId = romFs:version(),
    mapId = mapId,
    mapSymbol = resolved.map.symbol,
    label = resolved.map.label,
    matrix = {
      memberId = resolved.matrixMemberId,
      name = resolved.matrix.name,
      width = resolved.matrix.width,
      height = resolved.matrix.height,
      x = resolved.matrixX,
      z = resolved.matrixZ,
      index = resolved.matrixIndex,
      altitude = resolved.matrixAltitude,
      worldOriginX = resolved.worldOriginX,
      worldOriginZ = resolved.worldOriginZ,
    },
    area = {
      memberId = resolved.areaDataMemberId,
      type = area.areaType,
      mapTexturePackId = area.mapTexturePackId,
      buildingTexturePackId = area.buildingTexturePackId,
      dynamicTextureType = area.dynamicTextureType,
      lightType = area.lightType,
    },
    cameraType = resolved.map.cameraType,
    collision = {
      width = 32,
      height = 32,
      file = MapAssetCache.mapDir(mapId) .. "/permissions.bin",
    },
    mapBatches = mapCompiled.batches,
    materials = mapCompiled.materials,
    buildingInstances = buildingInstances,
    neighbors = neighbors,
    calibration = { modelExtentTilesX = exTiles, modelExtentTilesZ = ezTiles,
      posScale = mapModel.info.posScale },
    source = {
      romSha1 = romSha1,
      mapMatrix = { alias = "map_matrices", memberId = resolved.matrixMemberId, sha1 = dependencies.matrixMemberSha1 },
      areaData = { alias = "area_data", memberId = resolved.areaDataMemberId, sha1 = dependencies.areaDataMemberSha1 },
      landData = { alias = "land_data", memberId = resolved.landDataMemberId, sha1 = dependencies.landDataMemberSha1 },
      mapTexture = { alias = "map_textures", memberId = area.mapTexturePackId, sha1 = dependencies.mapTextureMemberSha1 },
    },
    limitations = {
      dynamicTexturesStatic = true,
      bdhcNotUsedForPlayerHeight = true,
      approximateCamera = true,
    },
    lighting = {
      lightTypeRaw = area.lightTypeRaw,
      profileId = selectedLight.profileId,
      sourcePath = selectedLight.sourcePath,
      sourceSha1 = lightSha1,
      parserVersion = FieldLightProfile.VERSION,
      records = lightProfile.records,
    },
  }

  return {
    mapId = mapId,
    marker = marker,
    scene = scene,
    dependencies = dependencies,
    permissions = land.permissionBytes,
    meshes = meshes,
    textures = textures,
    models = models,
  }
end

function MapAssetCompiler.compile(romFs, idOrSymbol)
  assert(romFs and romFs.openNarc, "compile requires a RomFs-shaped object")
  local ok, result = pcall(_compile, romFs, idOrSymbol)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

MapAssetCompiler.COMPILER_VERSION = COMPILER_VERSION
-- Exposed for the neighbour-ring chunk compiler, which reuses the exact batch
-- build (UV normalization, alpha classification, content hashing) on a single
-- terrain model without the full per-map resolve/scene/cache orchestration.
MapAssetCompiler.compileModel = compileModel

return MapAssetCompiler
