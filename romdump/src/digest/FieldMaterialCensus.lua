-- Real-ROM material census backing the specular decision: counts materials
-- and SPE_EMI bit 15 (useShininessTable) across every model class the field
-- renderer draws -- map models, placed-building models, and field-actor
-- models (shared actor archive plus static-model archive). Read-only: it
-- decodes material records and writes nothing. The decision whether any
-- HGSS field material carries the bit gates the shininess-table surface;
-- this census is the corpus backing for that decision, so it records the
-- tally and never assumes the outcome. `run` walks a RomFs and is the
-- LÖVE-side entry point; `lines` renders the tally for the analyze-maps
-- report. Pure domain module: no love.

local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapResolver = require("romdump.src.digest.MapResolver")
local AreaData = require("romdump.src.digest.AreaData")
local LandData = require("romdump.src.digest.LandData")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")

local FieldMaterialCensus = {}

local MODEL_MAGIC = "BMD0"

local function countMaterials(nsbmd)
  local materials, bit15 = 0, 0
  for _, mat in ipairs(nsbmd.models[1].materials) do
    materials = materials + 1
    if mat.useShininessTable then
      bit15 = bit15 + 1
    end
  end
  return materials, bit15
end

-- Decode one model member and fold its materials into `bucket`. Malformed
-- members are counted, never fatal: a census must still cover the corpus.
local function foldModel(bucket, bytes, opts)
  local ok, nsbmd = pcall(Nsbmd.decode, bytes, opts)
  if not ok then
    bucket.decodeFailures = bucket.decodeFailures + 1
    return
  end
  if not nsbmd then
    bucket.decodeFailures = bucket.decodeFailures + 1
    return
  end
  bucket.models = bucket.models + 1
  local materials, bit15 = countMaterials(nsbmd)
  bucket.materials = bucket.materials + materials
  bucket.bit15 = bucket.bit15 + bit15
end

local function newTally()
  return {
    map = { resolved = 0, excluded = 0, models = 0, materials = 0, bit15 = 0, decodeFailures = 0 },
    buildings = { placements = 0, models = 0, materials = 0, bit15 = 0, decodeFailures = 0 },
    actors = { models = 0, nonModels = 0, materials = 0, bit15 = 0, decodeFailures = 0, archives = {} },
  }
end

-- Every map in the catalog: its land map model, plus the unique placed
-- building models of its area type (deduplicated across the corpus).
local function censusMapModels(romFs, tally)
  local landNarc = assert(romFs:openNarc("land_data"))
  local areaNarc = assert(romFs:openNarc("area_data"))
  local buildingNarcs = {}
  local seenBuildings = {}
  for record in MapCatalog.all() do
    local resolved = MapResolver.resolve(romFs, record.id)
    if not resolved or resolved.landDataMemberId == 0xFFFF then
      -- Excluded by the matrix: filler cells or cells whose land member is
      -- the 0xFFFF no-land-data sentinel (the MapAnalysis exclusion).
      tally.map.excluded = tally.map.excluded + 1
    else
      tally.map.resolved = tally.map.resolved + 1
      local area = assert(AreaData.decode(assert(areaNarc:readMember(resolved.areaDataMemberId)), {
        alias = "area_data",
        memberId = resolved.areaDataMemberId,
      }))
      local land = assert(LandData.decode(assert(landNarc:readMember(resolved.landDataMemberId)), {
        mapId = resolved.map.id,
        alias = "land_data",
        memberId = resolved.landDataMemberId,
      }))
      foldModel(tally.map, land.mapModelBytes, {
        alias = "land_data",
        memberId = resolved.landDataMemberId,
        section = "map-model",
      })
      if area.areaType == "indoor" or area.areaType == "outdoor" then
        local archiveAlias = area.areaType == "indoor" and "interior_build_models" or "exterior_build_models"
        local narc = buildingNarcs[archiveAlias]
        if not narc then
          narc = assert(romFs:openNarc(archiveAlias))
          buildingNarcs[archiveAlias] = narc
        end
        for _, placement in ipairs(land.buildings) do
          -- The 0xFFFF model-member sentinel is a placement with no model
          -- (the land-data empty marker, like the no-land-data cell
          -- sentinel); there is nothing to fold into the census.
          if placement.modelMemberId ~= 0xFFFF then
            tally.buildings.placements = tally.buildings.placements + 1
            local key = archiveAlias .. ":" .. placement.modelMemberId
            if not seenBuildings[key] then
              seenBuildings[key] = true
              foldModel(tally.buildings, assert(narc:readMember(placement.modelMemberId)), {
                alias = archiveAlias,
                memberId = placement.modelMemberId,
              })
            end
          end
        end
      end
    end
  end
end

-- Every model member of the field-actor archives, ordinary shared models and
-- static map-object models alike. The shared archive mixes BMD0 with texture
-- and timeline resources, so members are filtered by magic. The aggregate
-- counters derive from the per-archive tallies after both archives run.
local function censusActorModels(romFs, tally)
  for _, alias in ipairs({ "field_actor_models", "field_static_models" }) do
    local narc = assert(romFs:openNarc(alias))
    local archive = { alias = alias, models = 0, nonModels = 0, materials = 0, bit15 = 0, decodeFailures = 0 }
    tally.actors.archives[#tally.actors.archives + 1] = archive
    local count = narc:memberCount()
    for memberId = 0, count - 1 do
      local bytes = assert(narc:readMember(memberId))
      if bytes:sub(1, 4) ~= MODEL_MAGIC then
        archive.nonModels = archive.nonModels + 1
      else
        foldModel(archive, bytes, { alias = alias, memberId = memberId })
      end
    end
  end
  local actors = tally.actors
  for _, archive in ipairs(actors.archives) do
    actors.models = actors.models + archive.models
    actors.nonModels = actors.nonModels + archive.nonModels
    actors.materials = actors.materials + archive.materials
    actors.bit15 = actors.bit15 + archive.bit15
    actors.decodeFailures = actors.decodeFailures + archive.decodeFailures
  end
end

function FieldMaterialCensus.run(romFs)
  assert(romFs and romFs.openNarc, "census requires a RomFs-shaped object")
  local tally = newTally()
  censusMapModels(romFs, tally)
  censusActorModels(romFs, tally)
  return tally
end

-- The corpus-backed decision input: does ANY field material set SPE_EMI
-- bit 15? The implementation must not assume either outcome.
function FieldMaterialCensus.anyBit15(tally)
  return tally.map.bit15 + tally.buildings.bit15 + tally.actors.bit15 > 0
end

-- Deterministic, payload-free census lines for the analyze-maps report: one
-- line per model class, one per actor archive, and a corpus total whose
-- anyBit15 flag is the decision input.
function FieldMaterialCensus.lines(tally)
  local L = {}
  local function add(fmt, ...)
    L[#L + 1] = string.format(fmt, ...)
  end
  local m = tally.map
  add(
    "census\tmap-models\tmodels=%d\tmaterials=%d\tbit15=%d\tdecodeFailures=%d",
    m.models,
    m.materials,
    m.bit15,
    m.decodeFailures
  )
  local b = tally.buildings
  add(
    "census\tbuilding-models\tplacements=%d\tuniqueModels=%d\tmaterials=%d\tbit15=%d\tdecodeFailures=%d",
    b.placements,
    b.models,
    b.materials,
    b.bit15,
    b.decodeFailures
  )
  local a = tally.actors
  add(
    "census\tactor-models\tmodels=%d\tmaterials=%d\tbit15=%d\tdecodeFailures=%d",
    a.models,
    a.materials,
    a.bit15,
    a.decodeFailures
  )
  for _, archive in ipairs(a.archives) do
    add(
      "census\tactor-archive\t%s\tmodels=%d\tmaterials=%d\tbit15=%d\tdecodeFailures=%d",
      archive.alias,
      archive.models,
      archive.materials,
      archive.bit15,
      archive.decodeFailures
    )
  end
  local totalMaterials = m.materials + b.materials + a.materials
  local totalBit15 = m.bit15 + b.bit15 + a.bit15
  add(
    "census\ttotal\tmaterials=%d\tbit15=%d\tanyBit15=%s",
    totalMaterials,
    totalBit15,
    tostring(FieldMaterialCensus.anyBit15(tally))
  )
  return L
end

return FieldMaterialCensus
