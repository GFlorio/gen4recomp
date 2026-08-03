-- Target asset inspector. Turns a resolved map into a deterministic,
-- payload-free inventory of exactly what the map needs: field containers,
-- map-model geometry, texture packs, and placed-building models. It is the
-- observable surface for reviewing the target texture and geometry inventory:
-- every set is sorted, and every unsupported format/opcode surfaces as a
-- structured decode error rather than silent success.
--
-- It runs under LÖVE (it needs an open RomFs) but holds no draw state and
-- writes nothing to the repository. Raw formats stop here: it hands the rest of
-- the pipeline normalized records, never NARC offsets.

local MapResolver = require("src.data.MapResolver")
local AreaData = require("src.data.AreaData")
local LandData = require("src.data.LandData")
local Nsbmd = require("src.data.nitro.Nsbmd")
local Nsbtx = require("src.data.nitro.Nsbtx")
local GxDisplayList = require("src.data.nitro.GxDisplayList")

local MapAssetInspector = {}

local function sha1(bytes)
  if love and love.data then
    local raw = love.data.hash("sha1", bytes)
    return (raw:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
  end
  return nil
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- Read a NARC member, validating the id against the archive size (spec 10.3 /
-- 13.5). Returns bytes, member sha1.
local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count))
  local bytes = assert(narc:readMember(memberId))
  return bytes, sha1(bytes)
end

-- Aggregate GX opcode counts across a model's shapes into a name->count map.
local function collectGxOpcodes(model)
  local counts = {}
  for _, shp in ipairs(model.shapes) do
    for op, n in pairs(shp.opcodeCounts) do
      local name = GxDisplayList.opcodeName(op) or string.format("0x%02X", op)
      counts[name] = (counts[name] or 0) + n
    end
  end
  return counts
end

local function collectSbcOpcodes(model)
  local counts = {}
  for _, cmd in ipairs(model.sbc.commands) do
    counts[cmd.name] = (counts[cmd.name] or 0) + 1
  end
  return counts
end

local function summarizeTexturePack(nsbtx)
  local formats, dims, names, palNames = {}, {}, {}, {}
  for _, t in ipairs(nsbtx.textures) do
    formats[t.format] = true
    dims[string.format("%dx%d", t.width, t.height)] = true
    names[#names + 1] = t.name
  end
  for _, p in ipairs(nsbtx.palettes) do palNames[#palNames + 1] = p.name end
  table.sort(names)
  table.sort(palNames)
  return {
    textureCount = #nsbtx.textures,
    paletteCount = #nsbtx.palettes,
    formats = sortedKeys(formats),
    dimensions = sortedKeys(dims),
    names = names,
    paletteNames = palNames,
  }
end

local function summarizeMapModel(nsbmd)
  local model = nsbmd.models[1]
  local texNames, palNames = {}, {}
  for _, a in ipairs(model.textureAssociations) do texNames[#texNames + 1] = a.name end
  for _, a in ipairs(model.paletteAssociations) do palNames[#palNames + 1] = a.name end
  table.sort(texNames); table.sort(palNames)
  return {
    modelCount = #nsbmd.models,
    modelName = model.name,
    nodeCount = model.info.numNode,
    materialCount = model.info.numMat,
    shapeCount = model.info.numShp,
    vertexCount = model.info.numVertex,
    sbcOpcodes = collectSbcOpcodes(model),
    gxOpcodes = collectGxOpcodes(model),
    referencedTextureNames = texNames,
    referencedPaletteNames = palNames,
    bounds = model.bounds,
    embeddedTextures = nsbmd.embeddedTextures ~= nil,
  }
end

-- Decode every unique placed-building model in the archive chosen by area type.
local function inspectBuildings(romFs, area, buildings, warnings)
  local alias = area.areaType == "indoor" and "interior_build_models"
    or area.areaType == "outdoor" and "exterior_build_models"
  if not alias then
    warnings[#warnings + 1] = "unsupported area type for building selection: " .. tostring(area.areaTypeRaw)
    return { archiveAlias = nil, modelIds = {}, placements = #buildings, modelSummaries = {} }
  end

  local uniqueIds = {}
  for _, b in ipairs(buildings) do uniqueIds[b.modelMemberId] = true end
  local ids = sortedKeys(uniqueIds)

  local narc = assert(romFs:openNarc(alias))
  local summaries = {}
  for _, memberId in ipairs(ids) do
    local ok, bytes = pcall(readMember, narc, alias, memberId)
    if not ok then
      warnings[#warnings + 1] = string.format("building model %d: %s", memberId, tostring(bytes))
    else
      local nsbmd, err = Nsbmd.decode(bytes, { alias = alias, memberId = memberId })
      if not nsbmd then
        warnings[#warnings + 1] = string.format("building model %d decode failed: %s", memberId, tostring(err))
      else
        local model = nsbmd.models[1]
        summaries[#summaries + 1] = {
          memberId = memberId,
          modelName = model.name,
          nodeCount = model.info.numNode,
          materialCount = model.info.numMat,
          shapeCount = model.info.numShp,
          hasEmbeddedTextures = nsbmd.embeddedTextures ~= nil,
          bounds = model.bounds,
        }
      end
    end
  end
  return { archiveAlias = alias, modelIds = ids, placements = #buildings, modelSummaries = summaries }
end

-- Produce the full inventory report for a semantic map id or symbol.
function MapAssetInspector.inspect(romFs, idOrSymbol)
  local warnings = {}
  local resolved = assert(MapResolver.resolve(romFs, idOrSymbol))

  local areaNarc = assert(romFs:openNarc("area_data"))
  local areaBytes, areaSha = readMember(areaNarc, "area_data", resolved.areaDataMemberId)
  local area = assert(AreaData.decode(areaBytes, { alias = "area_data", memberId = resolved.areaDataMemberId }))

  local landNarc = assert(romFs:openNarc("land_data"))
  local landBytes, landSha = readMember(landNarc, "land_data", resolved.landDataMemberId)
  local land = assert(LandData.decode(landBytes,
    { mapId = resolved.map.id, alias = "land_data", memberId = resolved.landDataMemberId }))
  -- LandData already decoded the placed-building records; reuse them.
  local buildings = land.buildings

  local mapModel = assert(Nsbmd.decode(land.mapModelBytes,
    { alias = "land_data", memberId = resolved.landDataMemberId, section = "map-model" }))

  local mapTexNarc = assert(romFs:openNarc("map_textures"))
  local mapTexBytes, mapTexSha = readMember(mapTexNarc, "map_textures", area.mapTexturePackId)
  local mapTexPack = assert(Nsbtx.decode(mapTexBytes,
    { alias = "map_textures", memberId = area.mapTexturePackId }))

  local bldTexNarc = assert(romFs:openNarc("building_textures"))
  local bldTexBytes, bldTexSha = readMember(bldTexNarc, "building_textures", area.buildingTexturePackId)
  local bldTexPack = assert(Nsbtx.decode(bldTexBytes,
    { alias = "building_textures", memberId = area.buildingTexturePackId }))

  local report = {
    versionId = romFs:version(),
    map = {
      id = resolved.map.id,
      symbol = resolved.map.symbol,
      matrixMemberId = resolved.matrixMemberId,
      areaDataMemberId = resolved.areaDataMemberId,
      eventMemberId = resolved.map.eventMemberId,
    },
    resolved = {
      matrixName = resolved.matrix.name,
      matrixWidth = resolved.matrix.width,
      matrixHeight = resolved.matrix.height,
      matrixX = resolved.matrixX,
      matrixZ = resolved.matrixZ,
      matrixIndex = resolved.matrixIndex,
      landDataMemberId = resolved.landDataMemberId,
      altitude = resolved.matrixAltitude,
      worldOriginX = resolved.worldOriginX,
      worldOriginZ = resolved.worldOriginZ,
    },
    area = {
      buildingTexturePackId = area.buildingTexturePackId,
      mapTexturePackId = area.mapTexturePackId,
      dynamicTextureType = area.dynamicTextureType,
      areaType = area.areaType,
      lightType = area.lightType,
    },
    land = {
      memberSize = #landBytes,
      bgsPayloadSize = #land.bgs.payload,
      permissionsSize = land.sizes.permissions,
      buildingSectionSize = land.sizes.buildings,
      buildingCount = #buildings,
      modelSize = land.sizes.model,
      bdhcSize = land.sizes.bdhc,
      modelMagic = land.mapModelBytes:sub(1, 4),
      bdhcMagic = land.sizes.bdhc > 0 and land.bdhcBytes:sub(1, 4) or "",
      collisionValues = land.permissions:usedCollisionValues(),
      terrainValues = land.permissions:usedTerrainValues(),
    },
    mapModel = summarizeMapModel(mapModel),
    mapTexturePack = summarizeTexturePack(mapTexPack),
    buildingTexturePack = summarizeTexturePack(bldTexPack),
    buildings = inspectBuildings(romFs, area, buildings, warnings),
    source = {
      areaData = { alias = "area_data", memberId = resolved.areaDataMemberId, sha1 = areaSha },
      landData = { alias = "land_data", memberId = resolved.landDataMemberId, sha1 = landSha },
      mapTexture = { alias = "map_textures", memberId = area.mapTexturePackId, sha1 = mapTexSha },
      buildingTexture = { alias = "building_textures", memberId = area.buildingTexturePackId, sha1 = bldTexSha },
    },
    warnings = warnings,
  }
  return report
end

-- Format a report as a deterministic, human-readable line list for stdout.
function MapAssetInspector.lines(report)
  local L = {}
  local function add(fmt, ...) L[#L + 1] = string.format(fmt, ...) end
  add("== %s :: %s (id %d) ==", report.versionId, report.map.symbol, report.map.id)
  add("resolved: matrix %q %dx%d cell (%d,%d) index %d land %d origin (%d,%d)",
    report.resolved.matrixName, report.resolved.matrixWidth, report.resolved.matrixHeight,
    report.resolved.matrixX, report.resolved.matrixZ, report.resolved.matrixIndex,
    report.resolved.landDataMemberId, report.resolved.worldOriginX, report.resolved.worldOriginZ)
  add("area: type=%s mapTexPack=%d bldTexPack=%d dynTex=0x%X light=%d",
    report.area.areaType, report.area.mapTexturePackId, report.area.buildingTexturePackId,
    report.area.dynamicTextureType, report.area.lightType)
  local l = report.land
  add("land: size=%d bgs=%d perms=0x%X buildings=%d(%d recs) model=%d bdhc=%d magic=%s",
    l.memberSize, l.bgsPayloadSize, l.permissionsSize, l.buildingSectionSize, l.buildingCount,
    l.modelSize, l.bdhcSize, l.modelMagic)
  add("  collision values: %s", table.concat(l.collisionValues, " "))
  local mm = report.mapModel
  add("mapModel: %s models=%d nodes=%d materials=%d shapes=%d verts=%d",
    mm.modelName, mm.modelCount, mm.nodeCount, mm.materialCount, mm.shapeCount, mm.vertexCount)
  add("  bounds min(%.2f,%.2f,%.2f) max(%.2f,%.2f,%.2f)",
    mm.bounds.min[1], mm.bounds.min[2], mm.bounds.min[3],
    mm.bounds.max[1], mm.bounds.max[2], mm.bounds.max[3])
  local function opcodeLine(label, counts)
    local parts = {}
    for _, name in ipairs(sortedKeys(counts)) do parts[#parts + 1] = name .. "=" .. counts[name] end
    add("  %s: %s", label, table.concat(parts, " "))
  end
  opcodeLine("SBC opcodes", mm.sbcOpcodes)
  opcodeLine("GX opcodes", mm.gxOpcodes)
  add("  textures referenced: %s", table.concat(mm.referencedTextureNames, " "))
  local mt = report.mapTexturePack
  add("mapTexturePack: %d textures %d palettes formats=[%s] dims=[%s]",
    mt.textureCount, mt.paletteCount, table.concat(mt.formats, ","), table.concat(mt.dimensions, ","))
  local bt = report.buildingTexturePack
  add("buildingTexturePack: %d textures %d palettes formats=[%s]",
    bt.textureCount, bt.paletteCount, table.concat(bt.formats, ","))
  local b = report.buildings
  add("buildings: archive=%s placements=%d uniqueModels=[%s]",
    tostring(b.archiveAlias), b.placements, table.concat(b.modelIds, ","))
  for _, s in ipairs(b.modelSummaries) do
    add("  model %d %q: nodes=%d materials=%d shapes=%d embeddedTex=%s",
      s.memberId, s.modelName, s.nodeCount, s.materialCount, s.shapeCount, tostring(s.hasEmbeddedTextures))
  end
  if #report.warnings == 0 then
    add("warnings: none")
  else
    table.sort(report.warnings)
    for _, w in ipairs(report.warnings) do add("WARNING: %s", w) end
  end
  return L
end

return MapAssetInspector
