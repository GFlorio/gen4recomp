-- Static evaluator for an NSBMD model's SBC draw stream: the bind-pose draw
-- record set the map compiler bakes geometry with.
--
-- The pose-driven evaluator (NsbmdSbcEvaluator) replays the compiled
-- transform program under a pose provider; with the bind-pose provider this
-- reproduces the static draw records exactly, so this module is that
-- evaluation and nothing more -- the bind-pose equivalence invariant is
-- checked in romdump/tests/nsbmd_dynamic_mesh_test.lua (static batches vs
-- dynamic meshes resolved at the bind pose).
--
-- Pure domain module: no love dependency.

local NsbmdSbcEvaluator = require("libs.engine.src.NsbmdSbcEvaluator")
local NsbmdTransformProgram = require("romdump.src.digest.NsbmdTransformProgram")
local NsbmdPoseProvider = require("romdump.src.digest.NsbmdPoseProvider")

local NsbmdStaticTransforms = {}

-- Replay the SBC stream for `model` and return the ordered draw submissions
-- at the bind pose (the shape documented by NsbmdSbcEvaluator.evaluate):
--
--   {
--     nodeIndex, materialIndex, shapeIndex, materialReapplied,
--     matrix = <16-element column-major matrix>,
--     restoreStack = { [slot] = <matrix>, ... },
--     transformMode = "static" | "billboard",
--     baseTransform = <matrix>,  -- billboard draws only
--   }
function NsbmdStaticTransforms.evaluate(model)
  assert(type(model) == "table" and model.sbc ~= nil, "NsbmdStaticTransforms.evaluate requires a decoded Nsbmd model")
  return NsbmdSbcEvaluator.evaluate(NsbmdTransformProgram.compile(model), NsbmdPoseProvider.bindPose(model)).draws
end

return NsbmdStaticTransforms
