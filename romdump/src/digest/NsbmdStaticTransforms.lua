-- Static evaluator for an NSBMD model's SBC draw stream: the bind-pose draw
-- record set the map compiler bakes geometry with.
--
-- The pose-driven evaluator (NsbmdSbcEvaluator) replays the compiled
-- transform program under a pose provider; this module is that evaluation
-- and nothing more -- it owns the bind-pose provider (every node at its
-- model bind SRT) and returns the program it compiled, so the dynamic mesh
-- path reuses the same compile instead of building a second one. The
-- bind-pose equivalence invariant is checked in
-- romdump/tests/nsbmd_dynamic_mesh_test.lua (static batches vs dynamic
-- meshes resolved at the bind pose).
--
-- Pure domain module: no love dependency.

local NsbmdSbcEvaluator = require("libs.assets.src.NsbmdSbcEvaluator")
local NsbmdTransformProgram = require("romdump.src.digest.NsbmdTransformProgram")

local NsbmdStaticTransforms = {}

-- Replay the SBC stream for `model` and return the ordered draw submissions
-- at the bind pose (the shape documented by NsbmdSbcEvaluator.evaluate),
-- plus the compiled transform program:
--
--   {
--     nodeIndex, materialIndex, shapeIndex, materialReapplied,
--     matrix = <16-element column-major matrix>,
--     restoreStack = { [slot] = <matrix>, ... },
--     transformMode = "static" | "billboard",
--     baseTransform = <matrix>,  -- billboard draws only
--   }
--   , program
function NsbmdStaticTransforms.evaluate(model)
  assert(type(model) == "table" and model.sbc ~= nil, "NsbmdStaticTransforms.evaluate requires a decoded Nsbmd model")
  local program = NsbmdTransformProgram.compile(model)
  -- The bind-pose provider: the model's decoded node records unchanged.
  -- nodeSRT falls back to nil for nodes the model does not carry (the
  -- evaluator then raises, exactly like the static path).
  local nodes = model.nodes
  local function nodeSRT(nodeIndex)
    assert(type(nodeIndex) == "number", "nodeSRT requires a numeric node index")
    return nodes[nodeIndex + 1]
  end
  local draws = NsbmdSbcEvaluator.evaluate(program, {
    nodeSRT = nodeSRT,
  }).draws
  return draws, program
end

return NsbmdStaticTransforms
