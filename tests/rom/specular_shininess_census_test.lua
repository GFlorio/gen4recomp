-- ROM-conformance regression assertion for one corpus decision: whether any
-- HGSS field material sets SPE_EMI bit 15 (useShininessTable), decided
-- between dropping the shininess-table surface and adding a shared-table
-- path. The corpus finding is recorded in the implementation notes
-- (2026-08-13: no material of any field model class sets bit 15).
--
-- depthEqual corpus evidence lives solely in
-- tests/rom/field_render_state_census_test.lua; this file does not
-- duplicate that authority.

local Assert = require("tests.support.Assert")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapResolver = require("romdump.src.digest.MapResolver")
local AreaData = require("romdump.src.digest.AreaData")
local LandData = require("romdump.src.digest.LandData")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")

local T = {}

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
-- members are counted, never fatal: the assertion must still cover the
-- corpus.
local function foldModel(bucket, bytes, opts)
  local ok, nsbmd = pcall(Nsbmd.decode, bytes, opts)
  if not ok or not nsbmd then
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
          -- (the land-data empty marker); there is nothing to fold in.
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
-- and timeline resources, so members are filtered by magic.
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

local function catalogCount()
  local count = 0
  for _ in MapCatalog.all() do
    count = count + 1
  end
  return count
end

-- One pass over the corpus (all catalog records, all actor archive members);
-- every postcondition is asserted against the same census result, and the
-- recorded bit-15 finding is pinned as a regression assertion.
function T.field_material_corpus_keeps_the_recorded_bit15_finding(romFs)
  local tally = newTally()
  censusMapModels(romFs, tally)
  censusActorModels(romFs, tally)

  -- The census iterated the full catalog: every record either resolved to a
  -- land member or was excluded by the matrix (filler cells, no land data).
  Assert.equal(tally.map.resolved + tally.map.excluded, catalogCount())
  Assert.isTrue(tally.map.resolved > 0, "the census resolved renderable maps")

  -- Map models carry material records.
  Assert.isTrue(tally.map.models > 0, "map model members decoded")
  Assert.isTrue(tally.map.materials > 0, "map model materials counted")
  Assert.equal(tally.map.decodeFailures, 0, "every map model decoded cleanly")

  -- Placed building models resolve through the interior/exterior archives.
  Assert.isTrue(tally.buildings.placements > 0, "building placements found")
  Assert.isTrue(tally.buildings.models > 0, "unique building models decoded")
  Assert.isTrue(tally.buildings.materials > 0, "building model materials counted")

  -- Both field-actor archives contribute model members (the shared archive
  -- mixes BMD0 with texture/timeline members; the static archive is all
  -- models). Field-actor coverage must not silently come from one archive.
  Assert.isTrue(tally.actors.models > 0, "field actor model members decoded")
  Assert.isTrue(tally.actors.materials > 0, "field actor model materials counted")
  Assert.equal(#tally.actors.archives, 2)
  for _, archive in ipairs(tally.actors.archives) do
    Assert.isTrue(archive.models > 0, "actor archive " .. archive.alias .. " has models")
  end

  -- The recorded finding (implementation notes 2026-08-13): NO field material
  -- of any class sets SPE_EMI bit 15, so the shininess-table surface stays
  -- dropped. A dump whose materials carry the bit trips this assertion.
  Assert.equal(
    tally.map.bit15 + tally.buildings.bit15 + tally.actors.bit15,
    0,
    "the field corpus must keep the recorded bit-15 finding"
  )
end

return require("tests.rom.support.RomSuite").fromFacts(T)
