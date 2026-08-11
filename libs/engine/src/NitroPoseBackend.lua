-- NitroPoseBackend: the pose evaluator for models whose source is a Nitro
-- NSBMD (the "Nitro backend" of the pose contract). The effective transform
-- of a Nitro model comes from replaying its SBC draw stream -- NODEDESC
-- joint matrices, POSSCALE, MTX slot restores, NODEMIX, billboards -- over
-- the animated joint results, so the runtime cannot evaluate it from the
-- neutral IR alone; the digest side compiles that stream into the model's
-- transform program (NsbmdTransformProgram) and this backend executes it
-- with the pose provider built from the instance's joint attachments.
--
-- Sampling the attachments runs through CompiledNsbcaSampler over the
-- clips' compiled payloads (NsbcaClipCompiler, digest side) -- the runtime
-- never touches NSBCA bytes -- then the per-node results blend through
-- JointAnimBlend and compose into SRT records via NitroJointState, the
-- same steps the digest-side NsbcaPoseProvider follows over raw decodes.
--
-- The output is the PoseState: per-node matrices and visibility plus
-- per-mesh draw transforms -- a Nitro draw is not one node matrix, so every
-- dynamic mesh carries the matrix its transform source resolves to.
--
-- Geometry is compiled once; only these matrices change per frame. Pure
-- domain module.

---@class PoseState
---@field nodeMatrices { [integer]: number[] } -- [nodeIndex] = world matrix (model space)
---@field nodeVisible { [integer]: boolean } -- absent means visible
---@field drawMatrices { [string]: PoseDrawMatrix } -- per mesh id
---@field matrixSlots { [integer]: number[] } -- the matrix-stack slots as of
--  the end of the replay, tile space (engine units)

local Errors = require("libs.rom.src.Errors")
local JointAnimBlend = require("libs.engine.src.JointAnimBlend")
local NitroJointState = require("libs.engine.src.NitroJointState")
local CompiledNsbcaSampler = require("libs.engine.src.CompiledNsbcaSampler")
local NsbmdSbcEvaluator = require("libs.engine.src.NsbmdSbcEvaluator")
local PoseContract = require("libs.engine.src.PoseContract")
local Matrix4 = require("libs.math.src.Matrix4")

local NitroPoseBackend = {}

-- The linear part of a 4x4, as the direction matrix a segment resolves to.
local linear = Matrix4.linear

-- Convert a draw matrix to engine units: only the translation column
-- divides by the tile size (the uniform model-to-tile scale).
local function toTiles(m, tileScale)
  local out = {}
  for i = 1, 12 do
    out[i] = m[i]
  end
  out[13], out[14], out[15] = m[13] * tileScale, m[14] * tileScale, m[15] * tileScale
  out[16] = m[16]
  return out
end

-- The effective per-node SRT records from the instance's joint attachments:
-- sampling + blending per node, with channels the clips leave to the model
-- resolved against the program's bind SRTs.
local function nodeSrt(program, attachments)
  local srt = {}
  local entriesByNode = {}
  for _, attachment in ipairs(attachments) do
    if attachment.ratioFx > 0 then
      local clip = attachment.clip
      if not clip.compiled then
        Errors.raise(
          "POSE_NITRO_JOINT_CLIP_NOT_COMPILED",
          "joint clip "
            .. clip.id
            .. " on model "
            .. program.name
            .. " is not a compiled NSBCA clip; the Nitro backend cannot sample it",
          { clip = clip.id, model = program.name }
        )
      end
      for _, track in ipairs(clip.tracks) do
        local nodeIndex = attachment.binding.map[track.target]
        -- Targets that name nodes the program does not carry are ignored,
        -- like the digest-side provider's permissive binding.
        if nodeIndex ~= nil and program.nodes[nodeIndex + 1] then
          local list = entriesByNode[nodeIndex] or {}
          list[#list + 1] = {
            ratio = attachment.ratioFx,
            clip = clip,
            track = track,
            player = attachment.player,
          }
          entriesByNode[nodeIndex] = list
        end
      end
    end
  end
  for nodeIndex, entries in pairs(entriesByNode) do
    local contributed = {}
    for _, entry in ipairs(entries) do
      contributed[#contributed + 1] = {
        ratio = entry.ratio,
        result = CompiledNsbcaSampler.sample(entry.clip, entry.track.targetIndex, entry.player.frameFx),
      }
    end
    -- Every entry here carries a positive ratio, so the blend always has a
    -- contributor and never returns nil.
    srt[nodeIndex] = NitroJointState.srtFromBlend(JointAnimBlend.blend(contributed), program.nodes[nodeIndex + 1])
  end
  return srt
end

-- Resolve one mesh's position matrix against its draw record. A nil source
-- (baked billboard segments) resolves to identity.
---@param source DrawSource|nil
---@return number[] -- 16-element column-major matrix, engine units
local function resolvePosition(draw, source, tileScale)
  if source == PoseContract.DRAW then
    return toTiles(draw.matrix, tileScale)
  end
  local slot = source and draw.restoreStack[source.slot]
  return toTiles(slot or Matrix4.identity(), tileScale)
end

-- Evaluate `instance` into a PoseState (see PoseBackend). Joint attachments
-- drive the program; material attachments do not affect the pose. The
-- definition is nitro by construction (there is no sourceBackend abstraction;
-- this backend IS the direct pose path).
function NitroPoseBackend.evaluate(instance)
  local def = instance.definition
  local backend = def.backend
  if not backend or not backend.program then
    Errors.raise(
      "POSE_NITRO_NO_TRANSFORM_PROGRAM",
      "model " .. def.key .. " has no compiled transform program in its backend payload",
      { modelKey = def.key }
    )
  end
  local program = backend.program

  local srt = nodeSrt(program, instance.animationState:attachments("joint"))
  local provider = {
    nodeSRT = function(nodeIndex)
      return srt[nodeIndex]
    end,
  }
  local result = NsbmdSbcEvaluator.evaluate(program, provider)

  local nodeVisible = {}
  for nodeIndex, visible in pairs(result.nodeVisibility) do
    if visible == false then
      nodeVisible[nodeIndex] = false
    end
  end

  local drawMatrices = {}
  for meshId, mesh in pairs(backend.meshes or {}) do
    local draw = result.draws[mesh.drawIndex + 1]
    if not draw then
      Errors.raise(
        "POSE_NITRO_DRAW_MISSING",
        "dynamic mesh "
          .. meshId
          .. " references draw "
          .. tostring(mesh.drawIndex)
          .. " which the program does not produce",
        { meshId = meshId, drawIndex = mesh.drawIndex, model = def.key }
      )
    end
    local position = resolvePosition(draw, mesh.positionSource, program.tileScale)
    ---@type PoseDrawMatrix
    local record = {
      position = position,
      direction = linear(position),
      transformMode = mesh.transformMode,
      baseTransform = nil,
    }
    -- A straddling mesh's leading vertices were submitted under the
    -- PRE-boundary source: resolve that matrix too, so the draw path can
    -- bend the first `leading` vertices per-vertex exactly like the DS
    -- geometry engine (the batch carries the split and the source).
    if mesh.straddle then
      local oldPosition = resolvePosition(draw, mesh.straddle.source, program.tileScale)
      record.straddle = {
        leading = mesh.straddle.leading,
        position = oldPosition,
        direction = linear(oldPosition),
      }
    end
    if record.transformMode == PoseContract.BILLBOARD then
      record.baseTransform =
        toTiles(assert(draw.baseTransform, "billboard draw carries no captured base transform"), program.tileScale)
    end
    drawMatrices[meshId] = record
  end

  local matrixSlots = {}
  for slot, m in pairs(result.matrixSlots or {}) do
    matrixSlots[slot] = toTiles(m, program.tileScale)
  end

  return {
    nodeMatrices = result.nodeMatrices,
    nodeVisible = nodeVisible,
    drawMatrices = drawMatrices,
    matrixSlots = matrixSlots,
  }
end

return NitroPoseBackend
