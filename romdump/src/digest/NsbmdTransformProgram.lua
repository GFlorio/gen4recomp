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
-- ROM bytes): the program is the digest-side face of the contract the
-- engine's NsbmdSbcEvaluator and NitroPoseBackend execute at runtime, so it
-- is compiled here next to the decoders that produce it. Compile-time
-- validation owns the static program invariants -- NODEMIX requires a rigid
-- inverse bind pose -- so the per-frame evaluator does not re-check them
-- every animation frame. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local MapUnits = require("romdump.src.digest.MapUnits")

local NsbmdTransformProgram = {}

-- The 4x3 part of a column-major matrix: the three basis columns plus the
-- translation. NODEMIX never sums the implicit fourth row.
local LINEAR_INDICES = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

-- One fx32 step: the quantum the bind-pose matrices are stored in.
local FX32_STEP = 1 / 4096

-- The SDK derives a draw's direction matrix as the linear part of its
-- position matrix; a NODEMIX blend reproduces the SDK's normal sum exactly
-- only when each joint's inverse normal matrix is the linear part of its
-- inverse position matrix (a rigid bind pose). This depends only on the
-- static program data, so it is rejected at compile time, once, instead of
-- inside every evaluation.
local function assertRigidBindPose(model, jointIndex)
  local evp = model.evpMatrices[jointIndex]
  for _, i in ipairs(LINEAR_INDICES) do
    if math.abs(evp.invN[i] - evp.invM[i]) > FX32_STEP then
      Errors.raise(
        "NSBMD_SBC_NODEMIX_NONRIGID_BIND_POSE",
        "NODEMIX joint has an inverse normal matrix that is not the linear part of "
          .. "its inverse position matrix, so blended normals need separate direction slots",
        { jointIndex = jointIndex, model = model.name, element = i, invM = evp.invM[i], invN = evp.invN[i] }
      )
    end
  end
end

-- Compile a decoded Nsbmd model (Nsbmd.decode(...).models[i]) into its
-- transform program. The model's decoded node records and SBC command
-- entries are already plain data and are reused by reference.
function NsbmdTransformProgram.compile(model)
  assert(
    type(model) == "table" and model.sbc ~= nil and model.info ~= nil,
    "NsbmdTransformProgram.compile requires a decoded Nsbmd model"
  )
  if model.evpMatrices then
    -- Validate exactly the joints a NODEMIX term references: every command
    -- of the linear SBC stream executes on every evaluation, so this is the
    -- same set the per-frame check used to cover, checked once here.
    for _, cmd in ipairs(model.sbc.commands) do
      if cmd.opcode == 0x09 then
        for _, term in ipairs(cmd.terms) do
          if model.evpMatrices[term.nodeIndex] then
            assertRigidBindPose(model, term.nodeIndex)
          end
        end
      end
    end
  end
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
