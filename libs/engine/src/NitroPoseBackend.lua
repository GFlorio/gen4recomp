-- NitroPoseBackend: the pose evaluator for models whose source is a Nitro
-- NSBMD (the "Nitro backend" of the pose contract). The effective transform
-- of a Nitro model comes from replaying its SBC draw stream -- NODEDESC
-- joint matrices, POSSCALE, MTX slot restores, NODEMIX, billboards -- over
-- the animated joint results, so the runtime cannot evaluate it from the
-- neutral IR alone; the digest side compiles that stream into the model's
-- transform program (the dynamic SBC evaluator epic) and this backend
-- executes it.
--
-- Until that program exists the backend is an explicit interface with a
-- loud, non-silent status: an instance of a nitro-backed model with joint or
-- visibility attachments raises POSE_NITRO_BACKEND_PENDING rather than
-- rendering wrong poses. With no such attachments there is nothing to
-- evaluate -- the static path renders the definition's baked meshes -- and
-- the backend returns nil.
--
-- The output contract is the PoseBackend PoseState: nodeMatrices (model
-- space), nodeVisible, and jointPalettes per skin. Material attachments are
-- evaluated by the material layer, not the pose backend. Pure domain module.

local Errors = require("libs.rom.src.Errors")

local NitroPoseBackend = {}

function NitroPoseBackend.evaluate(instance)
  local def = instance.definition
  if def.sourceBackend ~= "nitro" then
    Errors.raise("POSE_BACKEND_SOURCE_MISMATCH",
      "NitroPoseBackend cannot evaluate a " .. def.sourceBackend
        .. " model (" .. def.key .. ")",
      { sourceBackend = def.sourceBackend, modelKey = def.key })
  end
  if instance.animationState:hasAttachments("joint")
    or instance.animationState:hasAttachments("visibility") then
    Errors.raise("POSE_NITRO_BACKEND_PENDING",
      "model " .. def.key .. " needs the Nitro pose backend, which the dynamic "
        .. "SBC evaluator epic supplies; refusing to render a wrong pose",
      { modelKey = def.key })
  end
  return nil
end

return NitroPoseBackend
