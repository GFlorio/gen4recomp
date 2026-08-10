-- PoseBackend: the source-specific pose evaluation contract. A backend turns
-- a ModelInstance's definition plus its current animation state into the
-- effective model pose:
--
--   PoseState = {
--     nodeMatrices = { [nodeIndex] = 16-element column-major matrix },
--     nodeVisible  = { [nodeIndex] = boolean },   -- absent means visible
--     jointPalettes = { [skinId] = { [jointIndex] = matrix } },
--     drawMatrices = nil | { [meshId] = { position, direction,
--       transformMode, baseTransform } },  -- nitro backend only
--   }
--
-- drawMatrices carries the per-mesh draw transforms of the Nitro backend
-- (a Nitro draw is not one node matrix): ModelInstance.drawItems prefers
-- them over the node-matrix path when present.
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

-- The pose evaluation result shared by every backend: per-node matrices and
-- visibility, joint palettes for skinned models, and (Nitro backend only)
-- the per-mesh draw records. See docs/model-ir.md "PoseState".
---@class PoseState
---@field nodeMatrices { [integer]: number[] }
---@field nodeVisible { [integer]: boolean } -- absent means visible
---@field jointPalettes { [string]: { [integer]: number[] } }
---@field drawMatrices { [string]: PoseDrawMatrix }|nil

-- Evaluate the current pose of `instance`. Returns a PoseState. Raises a
-- structured error when the definition's backend cannot evaluate its current
-- attachments (no silent fallback).
---@return PoseState
function PoseBackend.evaluate(instance)
  assert(type(instance) == "table" and instance.definition ~= nil, "PoseBackend.evaluate requires a ModelInstance")
  local backend = BACKENDS[instance.definition.sourceBackend]
  if not backend then
    Errors.raise(
      "POSE_UNKNOWN_SOURCE_BACKEND",
      "model "
        .. instance.definition.key
        .. " has unknown source backend "
        .. tostring(instance.definition.sourceBackend),
      { sourceBackend = instance.definition.sourceBackend, modelKey = instance.definition.key }
    )
  end
  return backend.evaluate(instance)
end

return PoseBackend
