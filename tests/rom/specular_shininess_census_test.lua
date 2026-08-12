-- ROM-conformance census for the specular decision: whether any HGSS field
-- material sets SPE_EMI bit 15 (useShininessTable) decides between dropping
-- the shininess-table surface and adding a shared-table path, so the
-- decision must be corpus-backed. The census covers every model class the
-- field renderer draws -- map models, placed-building models, and
-- field-actor models (shared actor archive plus static-model archive) --
-- over the whole map catalog. It is read-only and asserts coverage, never
-- the outcome: the bit15 finding is recorded in the implementation notes,
-- not assumed here.

local Assert = require("tests.support.Assert")
local FieldMaterialCensus = require("romdump.src.digest.FieldMaterialCensus")
local MapCatalog = require("romdump.src.digest.MapCatalog")

local T = {}

local function catalogCount()
  local count = 0
  for _ in MapCatalog.all() do
    count = count + 1
  end
  return count
end

-- One pass over the corpus (all 540 catalog records, all actor archive
-- members); every postcondition is asserted against the same census result.
function T.field_material_census_covers_all_three_model_classes(romFs)
  local tally = FieldMaterialCensus.run(romFs)

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

  -- The corpus-backed finding is a recorded boolean; neither outcome is
  -- assumed (the decision lands in the implementation notes).
  Assert.isTrue(type(FieldMaterialCensus.anyBit15(tally)) == "boolean")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
