-- Tests for the specular census report surface: the corpus tally
-- renders as deterministic lines covering all three model classes, the
-- actor archives, and a corpus total whose anyBit15 flag is the decision
-- input. The real-ROM census run itself is the rom-layer contract
-- (tests/rom/specular_shininess_census_test.lua); this suite pins the
-- report shape and the aggregation with a synthetic tally.

local Assert = require("tests.support.Assert")
local FieldMaterialCensus = require("romdump.src.digest.FieldMaterialCensus")

local T = {}

-- A tally with distinctive numbers per class (bit15 set only on building
-- materials) so the per-class lines and the total aggregation are exact.
local function tally()
  return {
    map = { resolved = 12, excluded = 2, models = 12, materials = 100, bit15 = 0, decodeFailures = 0 },
    buildings = { placements = 30, models = 7, materials = 50, bit15 = 3, decodeFailures = 1 },
    actors = {
      models = 5,
      nonModels = 900,
      materials = 10,
      bit15 = 0,
      decodeFailures = 0,
      archives = {
        { alias = "field_actor_models", models = 2, nonModels = 850, materials = 4, bit15 = 0, decodeFailures = 0 },
        { alias = "field_static_models", models = 3, nonModels = 50, materials = 6, bit15 = 0, decodeFailures = 0 },
      },
    },
  }
end

-- The report must name each model class, each actor archive, and a corpus
-- total whose materials/bit15 sums and anyBit15 flag derive from the tally
-- (not from any hardcoded outcome).
function T.lines_cover_every_model_class_and_aggregate_the_total()
  local lines = FieldMaterialCensus.lines(tally())
  Assert.equal(#lines, 6)
  Assert.equal(lines[1], "census\tmap-models\tmodels=12\tmaterials=100\tbit15=0\tdecodeFailures=0")
  Assert.equal(
    lines[2],
    "census\tbuilding-models\tplacements=30\tuniqueModels=7\tmaterials=50\tbit15=3\tdecodeFailures=1"
  )
  Assert.equal(lines[3], "census\tactor-models\tmodels=5\tmaterials=10\tbit15=0\tdecodeFailures=0")
  Assert.equal(lines[4], "census\tactor-archive\tfield_actor_models\tmodels=2\tmaterials=4\tbit15=0\tdecodeFailures=0")
  Assert.equal(lines[5], "census\tactor-archive\tfield_static_models\tmodels=3\tmaterials=6\tbit15=0\tdecodeFailures=0")
  Assert.equal(lines[6], "census\ttotal\tmaterials=160\tbit15=3\tanyBit15=true")
  Assert.isTrue(FieldMaterialCensus.anyBit15(tally()))
end

return T
