-- PoseBackend: the source-specific pose evaluation contract. A backend turns
-- a ModelInstance's definition plus its current animation state into the
-- effective model pose:
--
--   PoseState = {
--     nodeMatrices = { [nodeIndex] = 16-element column-major matrix },
--     nodeVisible  = { [nodeIndex] = boolean },   -- absent means visible
--     jointPalettes = { [skinId] = { [jointIndex] = matrix } },
--   }
--
-- Backends are chosen by ModelDefinition.sourceBackend and must output the
-- same PoseState shape; they are free to use completely different internal
-- algorithms (the Nitro backend replays SBC matrix semantics, the generic
-- backend walks a TRS hierarchy) because only the final state is shared.
-- This module is the registry and the documented contract; it dispatches to
-- the backend modules and never interprets definition internals itself.
--
-- Pure domain module: no love.

local Errors = require("libs.rom.src.Errors")
local GenericPoseBackend = require("libs.engine.src.GenericPoseBackend")
local NitroPoseBackend = require("libs.engine.src.NitroPoseBackend")

local PoseBackend = {}

local BACKENDS = {
  generic = GenericPoseBackend,
  nitro = NitroPoseBackend,
}

-- Evaluate the current pose of `instance`. Returns a PoseState. Raises a
-- structured error when the definition's backend cannot evaluate its current
-- attachments (no silent fallback).
function PoseBackend.evaluate(instance)
  assert(type(instance) == "table" and instance.definition ~= nil,
    "PoseBackend.evaluate requires a ModelInstance")
  local backend = BACKENDS[instance.definition.sourceBackend]
  if not backend then
    Errors.raise("POSE_UNKNOWN_SOURCE_BACKEND",
      "model " .. instance.definition.key .. " has unknown source backend "
        .. tostring(instance.definition.sourceBackend),
      { sourceBackend = instance.definition.sourceBackend, modelKey = instance.definition.key })
  end
  return backend.evaluate(instance)
end

return PoseBackend
