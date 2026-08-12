-- NsbmdPoseProvider: the pose provider that feeds NsbmdSbcEvaluator at the
-- bind pose -- every node at its model bind SRT; the static path (and the
-- dynamic path's bind-pose evaluation) is that replay. The runtime's
-- animated path is the engine's NitroPoseBackend over compiled clips, which
-- follows the same composition steps (sampling -> JointAnimBlend ->
-- NitroJointState.srtFromBlend) over CompiledNsbcaSampler results.
--
-- Implements the pose-provider contract consumed by
-- NsbmdSbcEvaluator.evaluate(program, poseProvider):
--
--   nodeSRT(nodeIndex) -> SRT record | nil
--       -- nil falls back to the program's bind SRT
--
-- Pure domain module.

local NsbmdPoseProvider = {}

-- A provider that returns the model's decoded node records unchanged.
-- nodeSRT falls back to nil for nodes the model does not carry (the
-- evaluator then raises, exactly like the static path).
function NsbmdPoseProvider.bindPose(model)
  local nodes = model.nodes
  return {
    nodeSRT = function(nodeIndex)
      assert(type(nodeIndex) == "number", "nodeSRT requires a numeric node index")
      return nodes[nodeIndex + 1]
    end,
  }
end

return NsbmdPoseProvider
