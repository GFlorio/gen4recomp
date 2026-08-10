-- NsbmdTransformProgram: the compiled, serializable transform program of one
-- decoded NSBMD model. This is the asset-level shape the engine's
-- NsbmdSbcEvaluator and NitroPoseBackend execute at runtime -- the digest
-- side compiles every decoded SBC command, node record, and inverse-bind
-- block into plain data, and nothing in the runtime ever reads an SBC byte
-- again.
--
--   program = {
--     name,                        -- diagnostics only
--     scalingRule,                 -- NsbmdJointTransforms.STANDARD | MAYA
--     posScale, invPosScale,       -- POSSCALE factors (model units)
--     tileScale,                   -- engine-unit conversion for runtime
--                                  -- matrices: 1 / MODEL_UNITS_PER_TILE
--     nodes = {                    -- the decoded node SRT records
--       { index, name?, matrixStackIndex, translation, rotation, scale,
--         inverseScale, transZero, rotZero, scaleOne }, ...
--     },
--     commands = { ... },          -- decoded SBC entries, passed through
--     evpMatrices = { [joint] = { invM, invN } } | nil,
--   }
--
-- The compile is a projection of the decoded model (pure data selection, no
-- ROM bytes) so the program contract lives next to the evaluator that
-- consumes it. Pure domain module.

local MapUnits = require("romdump.src.digest.MapUnits")

local NsbmdTransformProgram = {}

-- Compile a decoded Nsbmd model (Nsbmd.decode(...).models[i]) into its
-- transform program. The model's decoded node records and SBC command
-- entries are already plain data and are reused by reference.
function NsbmdTransformProgram.compile(model)
  assert(
    type(model) == "table" and model.sbc ~= nil and model.info ~= nil,
    "NsbmdTransformProgram.compile requires a decoded Nsbmd model"
  )
  return {
    name = model.name,
    scalingRule = model.info.scalingRule,
    posScale = model.info.posScale,
    invPosScale = model.info.invPosScale,
    tileScale = 1 / MapUnits.MODEL_UNITS_PER_TILE,
    nodes = model.nodes,
    commands = model.sbc.commands,
    evpMatrices = model.evpMatrices,
  }
end

return NsbmdTransformProgram
