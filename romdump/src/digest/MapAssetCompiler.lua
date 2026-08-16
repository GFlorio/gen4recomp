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
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")
local HgssFieldLighting = require("romdump.src.digest.HgssFieldLighting")
local HgssFieldLightProfile = require("romdump.src.digest.HgssFieldLightProfile")
local HgssFieldEdgeColors = require("romdump.src.digest.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.HgssFieldFog")
local BuildingTransform = require("romdump.src.digest.BuildingTransform")
local MeshWriter = require("libs.assets.src.MeshWriter")
local MapUnits = require("romdump.src.digest.MapUnits")
local Hashing = require("romdump.src.digest.Hashing")
local Matrix4 = require("libs.math.src.Matrix4")
local VertexFormat = require("libs.assets.src.VertexFormat")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local NeighborPlan = require("romdump.src.digest.NeighborPlan")
local ModelAssetCompiler = require("romdump.src.digest.ModelAssetCompiler")
local NeighborChunkCompiler = require("romdump.src.digest.NeighborChunkCompiler")
local TerrainAnimationCompiler = require("romdump.src.digest.TerrainAnimationCompiler")
local Errors = require("libs.errors.src.Errors")
local AnimationClip = require("libs.assets.src.AnimationClip")
local NsbmdDynamicModel = require("romdump.src.digest.NsbmdDynamicModel")
local MapPropAnimCompiler = require("romdump.src.digest.MapPropAnimCompiler")
local ModelAsset = require("libs.assets.src.ModelAsset")
local PolygonState = require("libs.assets.src.PolygonState")

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

local function animListAliasForArea(area)
  if area.areaType == "indoor" then
    return "interior_build_anim_list"
  end
  if area.areaType == "outdoor" then
    return "exterior_build_anim_list"
  end
  Errors.raise(
    "MAP_COMPILE_UNSUPPORTED_AREA",
    "unsupported area type for building animation selection: " .. tostring(area.areaTypeRaw),
    { areaTypeRaw = area.areaTypeRaw }
  )
end

-- ---- animated model compile ----

-- The (texture, palette) variant names each pattern clip can select, per
-- targeted material name. The runtime binds variants by the same
-- texName[+plttName] keys (see MaterialEvaluator.variantFor).
local function patternVariants(clips)
  local byMaterial = {}
  for _, clip in ipairs(clips) do
    if clip.kind == AnimationClip.KINDS.PATTERN then
      local names = clip.compiled.textureNames
      local pltts = clip.compiled.paletteNames
      for _, target in ipairs(clip.compiled.targets) do
        local set = byMaterial[target.name] or {}
        for _, key in ipairs(target.keys) do
          local texName = names[key.texIdx + 1]
          local plttName
          if key.plttIdx ~= 0xFF then
            plttName = pltts[key.plttIdx + 1]
          end
          local variantName = plttName and (texName .. "+" .. plttName) or texName
          if not set[variantName] then
            set[variantName] = { texName = texName, plttName = plttName }
          end
        end
        byMaterial[target.name] = set
      end
    end
  end
  return byMaterial
end

-- Resolve every pattern variant against the model's embedded TEX0 (the
-- texture set the real BTP names bind against -- the area's external pack
-- does not carry them). Each variant decodes into the shared content-
-- addressed texture table; a name the TEX0 does not define yields an
-- untextured variant and an unresolved entry, mirroring the material
-- bind failures the DS exhibits. Returns per material name:
--   { { name, texture, width, height, textureFormat, alphaUsage } }
local function resolvePatternVariants(model, embeddedTex, variantSets, textures, unresolved, context)
  local byMaterial = {}
  for materialName, set in pairs(variantSets) do
    local variants = {}
    for variantName, pair in pairs(set) do
      local fakeMat = { name = variantName, textureName = pair.texName, paletteName = pair.plttName }
      local resolved =
        MaterialCompiler.resolveTexture(fakeMat, embeddedTex, textures, unresolved, { context = context })
      local variant = { name = variantName }
      if resolved.texture then
        variant.texture = MapAssetCache.texturePath(resolved.texture)
        variant.width = resolved.texWidth
        variant.height = resolved.texHeight
        variant.textureFormat = resolved.textureFormat
        variant.alphaUsage = textures[resolved.texture].alphaUsage
      end
      variants[variantName] = variant
    end
    byMaterial[materialName] = variants
  end
  return byMaterial
end

-- Merge the dynamic model's base material records with the compiled texture
-- records (base texture metadata, wrap/flip sampler state) and the pattern
-- variants.
local function dynamicMaterials(dynamicModel, matCompiled, textures, variantsByName)
  local out = {}
  for _, base in ipairs(dynamicModel.materials) do
    local merged = {}
    for k, v in pairs(base) do
      merged[k] = v
    end
    local m = matCompiled.materials[base.id + 1]
    if m then
      if m.texture then
        merged.texture = MapAssetCache.texturePath(m.texture)
        merged.textureFormat = m.textureFormat
        merged.alphaUsage = textures[m.texture].alphaUsage
      end
      merged.wrap = m.wrap
      merged.flip = m.flip
      merged.diffuse = m.diffuse
    end
    local variants = variantsByName[base.name]
    if variants then
      local list = {}
      for _, variant in pairs(variants) do
        list[#list + 1] = variant
      end
      table.sort(list, function(a, b)
        return a.name < b.name
      end)
      merged.variants = list
    end
    out[#out + 1] = merged
  end
  return out
end

-- Convert compiled dynamic segments into serializable descriptor records: the
-- geometry is encoded into the shared content-addressed mesh table and the
-- record references the path (never raw vertex arrays), and the polygon draw
-- state (cull mode, polygon mode/id, depth flags, polygon alpha, light mask)
-- is decoded per segment -- the same state the static path rides on each
-- batch. Segments that render neither surface ("all" cull) are skipped,
-- exactly like the static path.
local function dynamicBatches(dynamicModel, meshes)
  local out = {}
  for _, mesh in ipairs(dynamicModel.meshes) do
    local poly = DsPolygonAttr.decode(mesh.polygonAttrRaw)
    if poly.polygonMode ~= "modulation" and poly.polygonMode ~= "decal" then
      Errors.raise("MAP_COMPILE_UNSUPPORTED_POLYGON_MODE", "polygon mode " .. poly.polygonMode .. " is not supported", {
        polygonMode = poly.polygonMode,
        meshId = mesh.id,
      })
    end
    if poly.cullMode ~= "all" then
      local sha1 = Hashing.sha1hex(MeshWriter.encode(mesh.batch))
      meshes[sha1] = mesh.batch
      local record = {
        id = mesh.id,
        drawIndex = mesh.drawIndex,
        segmentIndex = mesh.segmentIndex,
        nodeIndex = mesh.nodeIndex,
        materialIndex = mesh.materialIndex,
        transformMode = mesh.transformMode,
        positionSource = mesh.positionSource,
        geometry = MapAssetCache.geometryPath(sha1),
      }
      -- The shared polygon draw-state field set (PolygonState.FIELDS).
      for _, field in ipairs(PolygonState.FIELDS) do
        record[field] = poly[field]
      end
      -- A run split at a mid-run matrix boundary: the batch's first
      -- `leading` vertices resolve under the pre-boundary source at draw
      -- time (the DS bends each vertex under the then-current matrix).
      if mesh.straddle then
        record.straddle = mesh.straddle
      end
      out[#out + 1] = record
    end
  end
  return out
end

-- Compile one animated model into its dynamic descriptor:
--   { schema, memberId, kind = "nitro-dynamic",
--     dynamic = { nodes, transformProgram, batches },
--     materials, animations }
-- The dynamic segments are encoded into content-addressed .g4mesh assets and
-- the descriptor references them by path; the transform program and the
-- compiled clips are plain serializable data. The runtime assembles the
-- ModelDefinition from this descriptor. The caller stamps `key` after hashing
-- the descriptor's content into the model key.
local function compileAnimatedModel(
  buildingModel,
  buildingNsbmd,
  texPack,
  animResult,
  context,
  memberId,
  textures,
  meshes
)
  local dynamicModel = NsbmdDynamicModel.compile(buildingModel)
  local base = MaterialCompiler.compile(buildingModel.materials, texPack, { context = context })
  for sha1, tex in pairs(base.textures) do
    textures[sha1] = tex
  end

  local unresolved = {}
  local embeddedTex = buildingNsbmd.embeddedTextures
  local variantsByName = {}
  if embeddedTex then
    variantsByName = resolvePatternVariants(
      buildingModel,
      embeddedTex,
      patternVariants(animResult.clips),
      textures,
      unresolved,
      context
    )
  elseif next(patternVariants(animResult.clips)) then
    -- A pattern animation on a model without an embedded texture block is
    -- an authoring anomaly; every variant stays untextured and reported.
    unresolved[#unresolved + 1] = {
      material = buildingModel.name,
      kind = "texture",
      name = "<pattern variants>",
      source = "model has no embedded TEX0",
    }
  end

  -- Wrap the raw MaterialCompiler-shaped entries with the model context, the
  -- same record shape the static path (ModelAssetCompiler.compileModel) reports.
  local wrapped = {}
  for _, entry in ipairs(unresolved) do
    wrapped[#wrapped + 1] = {
      role = context.role,
      modelArchive = context.modelArchive,
      modelMemberId = context.modelMemberId,
      modelName = context.modelName,
      material = entry.material,
      kind = entry.kind,
      name = entry.name,
      source = entry.source,
    }
  end

  return {
    schema = ModelAsset.SCHEMA,
    memberId = memberId,
    kind = "nitro-dynamic",
    dynamic = {
      nodes = dynamicModel.program.nodes,
      transformProgram = dynamicModel.program,
      batches = dynamicBatches(dynamicModel, meshes),
    },
    materials = dynamicMaterials(dynamicModel, base, textures, variantsByName),
    animations = animResult.clips,
  },
    wrapped
end

local function _compile(romFs, idOrSymbol, opts)
  opts = opts or {}
  local resolved = assert(MapResolver.resolve(romFs, idOrSymbol))
  local mapId = resolved.map.id
  local romSha1 = romFs:metadata().sha1

  -- Source members.
  local matrixNarc = assert(romFs:openNarc("map_matrices"))
  local matrixBytes = readMember(matrixNarc, "map_matrices", resolved.matrixMemberId)

  local areaNarc = assert(romFs:openNarc("area_data"))
  local areaBytes = readMember(areaNarc, "area_data", resolved.areaDataMemberId)
  local area = assert(AreaData.decode(areaBytes, { alias = "area_data", memberId = resolved.areaDataMemberId }))

  -- Terrain-animation compilation is map-scoped: one compiler parses the
  -- fldtanime table and serves every central and neighbor terrain compile,
  -- so all matched replacement members land in one dependency record, and
  -- the one area NSBTA clip is compiled from the central area's selection.
  local terrainAnimationCompiler = TerrainAnimationCompiler.new(romFs, {
    mapId = mapId,
    dynamicTextureType = area.dynamicTextureType,
  })

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
    schema = "g4-terrain-surfaces-v1",
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
    terrainAnimationCompiler = terrainAnimationCompiler,
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

  -- Animation-list archives: one 0x18-byte record per model member, whose
  -- resource ids index the shared animation archive (a/1/0/6). Interior and
  -- exterior lists live in separate archives; the resources are shared.
  local animListNarc, animResNarc
  if #memberIds > 0 then
    animListNarc = assert(romFs:openNarc(animListAliasForArea(area)))
    animResNarc = assert(romFs:openNarc("build_anim"))
  end

  local models, modelKeyOf, memberShaOf = {}, {}, {}
  local animDeps = {}
  for _, memberId in ipairs(memberIds) do
    local modelBytes = readMember(bldNarc, archiveAlias, memberId)
    local modelSha1 = Hashing.sha1hex(modelBytes)
    local buildingNsbmd = assert(Nsbmd.decode(modelBytes, { alias = archiveAlias, memberId = memberId }))
    local buildingModel = buildingNsbmd.models[1]
    local context = {
      mapId = mapId,
      mapSymbol = resolved.map.symbol,
      role = "building",
      areaDataMemberId = resolved.areaDataMemberId,
      landDataMemberId = resolved.landDataMemberId,
      textureArchive = "building_textures",
      textureMemberId = area.buildingTexturePackId,
      modelArchive = archiveAlias,
      modelMemberId = memberId,
      modelName = buildingModel.name,
      embeddedTex0Present = buildingNsbmd.embeddedTextures ~= nil,
      placementIndices = placementIndicesByMember[memberId],
    }
    local areaKind = area.areaType == "indoor" and "indoor" or "outdoor"

    -- Animated models compile through the dynamic path; static ones keep the
    -- optimized baked geometry.
    local modelDescriptor
    local animated = false
    if memberId < animListNarc:memberCount() then
      local listBytes = animListNarc:readMember(memberId)
      animDeps[#animDeps + 1] = { memberId = memberId, sha1 = Hashing.sha1hex(listBytes) }
      local animResult = MapPropAnimCompiler.compile(listBytes, animResNarc, {
        archiveAlias = animListAliasForArea(area),
        memberId = memberId,
        resourceCache = opts.resourceCache,
      })
      for _, clip in ipairs(animResult.clips) do
        animDeps[#animDeps + 1] = { resourceId = clip.source.memberId, sha1 = clip.source.sha1 }
      end
      if #animResult.clips > 0 then
        local descriptor, unresolved = compileAnimatedModel(
          buildingModel,
          buildingNsbmd,
          bldTexPack,
          animResult,
          context,
          memberId,
          textures,
          meshes
        )
        collectUnresolved({ unresolved = unresolved })
        modelDescriptor = descriptor
        animated = true
      end
    end

    if not animated then
      local compiled = ModelAssetCompiler.compileModel(buildingModel, bldTexPack, meshes, textures, context)
      collectUnresolved(compiled)
      modelDescriptor = {
        schema = ModelAsset.SCHEMA,
        memberId = memberId,
        kind = "static",
        batches = compiled.batches,
        materials = compiled.materials,
      }
    end

    -- The model key is content-addressed over the descriptor itself: the
    -- descriptor's runtime configuration depends on the model bytes, the
    -- animation list/resource bytes, the clip compiler semantics, the bound
    -- texture pack, and the pattern variants -- every immutable input --
    -- so the key hashes the final serialized descriptor rather than a subset
    -- of its inputs. Same member + same compiled content => same key across
    -- maps; any input change => a new path, never a stale descriptor.
    local descriptorSha = Hashing.hashLua(modelDescriptor)
    local modelKey = string.format("%s:%d:%s", areaKind, memberId, descriptorSha:sub(1, 12))
    modelDescriptor.key = modelKey
    models[modelKey] = modelDescriptor
    modelKeyOf[memberId] = modelKey
    memberShaOf[memberId] = modelSha1
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
      terrainAnimationCompiler = terrainAnimationCompiler,
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

  -- The one area texture-coordinate clip (or false) is compiled once after
  -- every central and neighbor terrain compile so the dependency record
  -- covers the whole ring; the neighbor areas' own selections are ignored.
  local textureSrt = terrainAnimationCompiler:compileTextureSrt()

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
    animationListMemberSha1s = animDeps,
  }
  -- The animation sources are producer provenance like every other
  -- dependency: the fldtanime table hash unconditionally, only the used
  -- replacement members, and the selected area NSBTA member -- merged before
  -- the marker hash so any animation source change invalidates the map.
  local terrainAnimDeps = terrainAnimationCompiler:dependencies()
  dependencies.fieldTextureAnimations = terrainAnimDeps.fieldTextureAnimations
  dependencies.terrainTextureSrt = terrainAnimDeps.terrainTextureSrt
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
    -- The central scene owns the one area texture-coordinate clip; the
    -- neighbor runtime receives it from the loader, never per-descriptor.
    terrainAnimations = { textureSrt = textureSrt },
    calibration = { modelExtentTilesX = exTiles, modelExtentTilesZ = ezTiles, posScale = mapModel.info.posScale },
    -- The runtime consumes only the normalized records for time-of-day
    -- selection; the source light type, profile id, source path, and source
    -- hash are producer provenance and live in the dependency record.
    lighting = {
      records = lightProfile.records,
    },
    -- The real HGSS edge-color table selected by the same per-area
    -- light-pattern byte HgssFieldLighting.resolve reads above (AreaData's
    -- lightTypeRaw at area-data offset 0x07 IS the byte AreaDataManager_Load
    -- reads at +0x8B7 to select between the two overlay tables). Field edge
    -- marking is unconditionally enabled, so every compiled scene carries
    -- this table.
    edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(area.lightTypeRaw),
    -- The map's base weather ID (MapCatalog record), carried alongside its
    -- resolved fog preset so a future runtime override policy (RTC/save/
    -- Defog/Flash) can start from the original ID rather than only the
    -- already-resolved preset.
    weatherId = resolved.map.weather,
    -- The resolved global HGSS weather fog preset for this map's real weather
    -- field, never a placeholder: every compiled scene carries it
    -- unconditionally, matching HGSS's own unconditional Fog_New()/
    -- WeatherManager_SetWeather call on field init. Derived from weatherId
    -- in this one place so the two fields cannot diverge.
    fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(resolved.map.weather)),
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

function MapAssetCompiler.compile(romFs, idOrSymbol, opts)
  assert(romFs and romFs.openNarc, "compile requires a RomFs-shaped object")
  local ok, result = pcall(_compile, romFs, idOrSymbol, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return MapAssetCompiler
