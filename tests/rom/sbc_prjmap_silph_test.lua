-- ROM-conformance regression for the corpus finding behind the SBC
-- strictness change: opcode 0x0D (PRJMAP) appears in real HGSS field data
-- (interior_build_models member 177 obj_sylph, placed on Silph Co. HQ), so
-- the evaluator's terminal unknown-opcode raise must not subsume it. Compiling
-- the map that places the model runs the real transform program through
-- NsbmdSbcEvaluator at digest time; the placed descriptor must carry the
-- PRJMAP command and evaluate to the same draw set.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local NsbmdSbcEvaluator = require("libs.assets.src.model.NsbmdSbcEvaluator")

local T = {}

local SILPH_HQ = "MAP_SAFFRON_SILPH_CO_HQ"
local SYLPH_MEMBER = 177

function T.placed_prjmap_model_compiles_and_evaluates(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, SILPH_HQ))

  -- The placed sylph model is animated and compiled through the dynamic
  -- path; its transform program carries the PRJMAP command the corpus found.
  local placedKey
  for _, inst in ipairs(bundle.scene.buildingInstances) do
    if inst.modelKey:sub(1, 11) == "indoor:177:" then
      placedKey = inst.modelKey
    end
  end
  Assert.notNil(placedKey, "Silph Co. HQ places interior model member 177")
  local descriptor = assert(bundle.models[placedKey], "the placed model has a compiled descriptor")
  Assert.equal(descriptor.kind, "nitro-dynamic")
  Assert.equal(descriptor.memberId, SYLPH_MEMBER)

  local program = descriptor.dynamic.transformProgram
  local prjmapCount = 0
  for _, cmd in ipairs(program.commands) do
    if cmd.opcode == 0x0D then
      prjmapCount = prjmapCount + 1
    end
  end
  Assert.isTrue(prjmapCount > 0, "the placed program contains the PRJMAP command")

  -- The real program evaluates cleanly at the bind pose (the digest compile
  -- above already proves it through production composition; this pins the
  -- evaluator contract directly).
  local draws = NsbmdSbcEvaluator.evaluate(program, {
    nodeSRT = function(nodeIndex)
      return program.nodes[nodeIndex + 1]
    end,
  }).draws
  Assert.isTrue(#draws > 0, "the PRJMAP-carrying program still submits draws")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
