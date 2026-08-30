-- ROM-conformance census behind the straddling-primitive contract: the real
-- HGSS field corpus contains primitives that span a mid-run matrix boundary,
-- so the dynamic compiler records their source provenance. The census pins
-- the exact straddle population of the heartgold dump (identified by
-- checksum), and every straddling mesh record must carry the source-boundary
-- metadata.

local Assert = require("tests.support.Assert")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local MeshCompiler = require("romdump.src.digest.MeshCompiler")
local BuildModelAnimList = require("romdump.src.digest.BuildModelAnimList")

local T = {}

-- Census every animated building model of both archives for straddling
-- primitives. Returns { models = <count>, shapes = <count>, straddles =
-- <count>, records = <count> } with the straddle-bearing models recorded by
-- member. `records` counts the mesh records carrying the per-vertex straddle
-- provenance; `straddles` counts the reported straddling primitives. Every
-- straddle a shape reports must be represented by exactly one provenance
-- record on the compiled mesh that carries its leading vertices.
local function censusStraddles(romFs, alias)
  local modelNarc = assert(romFs:openNarc(alias))
  local listNarc = assert(romFs:openNarc(alias:gsub("_models", "_anim_list")))
  local census = { models = 0, shapes = 0, straddles = 0, records = 0, byModel = {} }
  for memberId = 0, modelNarc:memberCount() - 1 do
    local listBytes = assert(listNarc:readMember(memberId), "anim-list record " .. memberId)
    local record = BuildModelAnimList.decode(listBytes)
    if #record.ids > 0 then
      local model =
        assert(Nsbmd.decode(assert(modelNarc:readMember(memberId)), { alias = alias, memberId = memberId })).models[1]
      local meshes, straddling = MeshCompiler.compileDynamic(model)
      -- Every straddle a shape reports is represented by exactly one
      -- source-boundary provenance record on the compiled mesh: the leading
      -- count and the pre-boundary source.
      local records = 0
      local sum = 0
      ---@type { straddle?: { leading: integer, source: table|string } }[]
      local compiledMeshes = meshes
      for _, mesh in ipairs(compiledMeshes) do
        if mesh.straddle then
          records = records + 1
          Assert.isTrue(mesh.straddle.leading >= 1, "straddle record names its leading vertices")
          Assert.isTrue(
            mesh.straddle.source == "draw" or type(mesh.straddle.source) == "table",
            "straddle record names its leading source"
          )
        end
      end
      if straddling and #straddling > 0 then
        for _, rec in ipairs(straddling) do
          sum = sum + rec.straddling
        end
        census.models = census.models + 1
        census.shapes = census.shapes + #straddling
        census.straddles = census.straddles + sum
        census.byModel[memberId] = {
          name = model.name,
          shapes = #straddling,
          straddles = sum,
        }
        Assert.equal(records, sum, "every reported straddle has one provenance record on its mesh")
        census.records = census.records + records
      end
    end
  end
  return census
end

-- The full straddle census of the heartgold dump: 4 interior models carry
-- 233 straddling primitives across 10 shapes. The measure is the compiled
-- provenance record: every straddle the compiler reports is represented by
-- exactly one record on its mesh, and a straddle whose receiving segment
-- never completes a primitive is not compiled (the DS discards incomplete
-- primitives too, and the empty-batch format gate forbids dead geometry) --
-- an earlier partial rebuild log recorded 2 models/5 shapes; the
-- decoder-level walk counted 374 boundary crossings including fragments
-- never compiled. No exterior model straddles.
function T.the_real_corpus_straddle_census_is_pinned(romFs, versionId, context)
  if versionId ~= "heartgold" then
    context:skip("the pinned straddle census covers HeartGold only")
  end
  Assert.equal(
    romFs:metadata().sha1,
    "4fcded0e2713dc03929845de631d0932ea2b5a37",
    "the census pins the heartgold dump (IPKE) checksum"
  )
  local interior = censusStraddles(romFs, "interior_build_models")
  local exterior = censusStraddles(romFs, "exterior_build_models")

  Assert.equal(interior.models, 4, "interior straddle-bearing models")
  Assert.equal(interior.shapes, 10, "interior straddle-bearing shapes")
  Assert.equal(interior.straddles, 233, "interior straddling primitives")
  Assert.equal(interior.records, 233, "every straddle carries its provenance record")
  Assert.equal(exterior.models, 0, "no exterior model straddles")
  Assert.equal(exterior.shapes, 0)
  Assert.equal(exterior.straddles, 0)
  Assert.equal(exterior.records, 0)

  -- The two real straddle-heavy models (Ecruteak Gym's rotating room walls):
  -- r07_00bot member 146 (3 shapes, 124 straddles) and r07_01bot member 147
  -- (3 shapes, 105 straddles), plus the Cianwood Gym lift pair mg06_fl1/fl2
  -- (members 173/174, 2 straddles each).
  Assert.equal(interior.byModel[146].straddles, 124)
  Assert.equal(interior.byModel[147].straddles, 105)
  Assert.equal(interior.byModel[173].straddles, 2)
  Assert.equal(interior.byModel[174].straddles, 2)
end

return require("tests.rom.support.RomSuite").fromFacts(T)
