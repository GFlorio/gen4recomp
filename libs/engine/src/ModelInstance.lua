-- ModelInstance: the per-model runtime object above the source backends. An
-- instance owns the placement transform, the animation state
-- (ModelAnimationState), the per-instance material state, and the last
-- evaluated pose; it is the only animation-facing API gameplay touches.
-- Nothing here knows NSBCA, NARC, SBC, matrix slots, or Nitro animation
-- resource indices -- a vanilla model and a future glTF model differ only in
-- ModelDefinition.sourceBackend, which selects the pose backend behind
-- PoseBackend.evaluate.
--
-- Usage per frame: instance:updateFixed() advances every attachment player,
-- instance:evaluatePose() recomputes the pose state through the backend,
-- then drawItems(renders) produces draw items in the production renderer's
-- shape (the same item contract MapRenderer consumes for map/building
-- draws). `renders` supplies the built mesh per mesh id (the caller builds
-- love meshes from the definition's mesh batches); drawItems itself stays
-- pure so pose and item math are testable without graphics.
--
-- The definition and its clips are immutable and shared; materialState is
-- the instance's own map, so two instances of one model can animate at
-- different frames and with different material overrides. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelAnimationState = require("libs.engine.src.ModelAnimationState")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local AnimationBinding = require("libs.engine.src.AnimationBinding")
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local PoseBackend = require("libs.engine.src.PoseBackend")

local ModelInstance = {}
ModelInstance.__index = ModelInstance

-- alphaMode -> the renderer's render-pass class (the material contract in
-- docs/model-ir.md).
local ALPHA_CLASS = {
  opaque = "opaque",
  mask = "cutout",
  blend = "translucent",
}

-- Fragment alpha cutoff for cutout materials; the same value the renderer
-- uses when an item carries no explicit cutoff (MapRenderer.CUTOUT_EPSILON).
local CUTOUT_EPSILON = 0.5 / 255

local function identityMatrix()
  return Matrix4.identity()
end

function ModelInstance.new(definition, opts)
  assert(type(definition) == "table" and definition.key ~= nil,
    "ModelInstance.new requires a ModelDefinition")
  opts = opts or {}
  local transform = opts.transform or identityMatrix()
  assert(type(transform) == "table" and #transform == 16,
    "instance transform must be a 16-element column-major matrix")

  local materialState = {}
  for _, material in ipairs(definition.materials) do
    materialState[material.id] = { alpha = 255 }
  end

  return setmetatable({
    definition = definition,
    transform = transform,
    animationState = ModelAnimationState.new(definition.key),
    materialState = materialState,
    poseState = nil,
  }, ModelInstance)
end

-- Advance every attachment player by one fixed step.
function ModelInstance:updateFixed()
  self.animationState:updateFixed()
end

-- Recompute the pose state from the current animation state through the
-- definition's pose backend. Returns the PoseState (nil for a nitro-backed
-- instance with nothing to evaluate). Raises a structured error when the
-- backend cannot evaluate (no silent fallback).
function ModelInstance:evaluatePose()
  self.poseState = PoseBackend.evaluate(self)
  return self.poseState
end

-- Start playing a clip, resolved by name or semantic role (e.g.
-- "door.open"). Binding and player setup happen here, once per play, never
-- per frame. `opts` passes through to the attachment: priority, ratioFx,
-- loopMode, repeatsRemaining, deltaFx, direction. Returns the attachment
-- token for stop(). Every play attaches an independent player, so several
-- clips -- and several plays of one clip -- can run simultaneously.
function ModelInstance:play(nameOrSemantic, opts)
  local clip = self.definition:animation(nameOrSemantic)
  if not clip then
    Errors.raise("ANIM_INSTANCE_UNKNOWN_ANIMATION",
      "model " .. self.definition.key .. " has no clip named " .. tostring(nameOrSemantic),
      { modelKey = self.definition.key, name = nameOrSemantic })
  end
  local binding = AnimationBinding.new(clip, self.definition.key,
    self.definition:bindingMap(clip))
  opts = opts or {}
  if opts.loopMode then
    assert(AnimationPlayer.LOOP_MODES[opts.loopMode],
      "loopMode must be loop, once, or repeat")
  end
  if opts.repeatsRemaining ~= nil then
    assert(opts.repeatsRemaining >= 1 and math.floor(opts.repeatsRemaining) == opts.repeatsRemaining,
      "repeatsRemaining must be a positive integer")
  end

  local player = opts.player or AnimationPlayer.new(clip)
  if opts.loopMode then player.loopMode = opts.loopMode end
  if opts.repeatsRemaining ~= nil then player.repeatsRemaining = opts.repeatsRemaining end
  if opts.deltaFx ~= nil then player:setDeltaFx(opts.deltaFx) end
  if opts.direction then player:setDirection(opts.direction) end

  return self.animationState:attach(clip, binding, {
    player = player,
    priority = opts.priority,
    ratioFx = opts.ratioFx,
  })
end

-- Stop a playing clip: by attachment token, or by name/semantic role (all
-- attachments of that clip). Returns the number of attachments removed.
function ModelInstance:stop(nameOrToken)
  local removed = 0
  for _, category in ipairs(ModelAnimationState.GROUPS) do
    for token, attachment in pairs(self.animationState.groups[category]) do
      local clip = attachment.clip
      local matchesName = false
      if type(nameOrToken) == "string" then
        if clip.name == nameOrToken or clip.id == nameOrToken then
          matchesName = true
        end
        for _, semantic in ipairs(clip.semanticNames) do
          if semantic == nameOrToken then matchesName = true end
        end
      end
      if (type(nameOrToken) == "number" and token == nameOrToken) or matchesName then
        self.animationState:detach(token)
        removed = removed + 1
      end
    end
  end
  return removed
end

-- The effective render material record for a material index: definition
-- properties plus this instance's state. Never mutates the definition.
function ModelInstance:effectiveMaterial(materialIndex)
  local material = assert(self.definition.materials[materialIndex + 1],
    "material index " .. tostring(materialIndex) .. " out of range")
  local state = self.materialState[materialIndex]
  return {
    image = material.texture,
    alphaClass = ALPHA_CLASS[material.alphaMode],
    alphaCutoff = material.alphaMode == "mask" and CUTOUT_EPSILON or nil,
    polygonAlpha = (state and state.alpha or 255) / 255,
    polygonMode = "modulation",
    polygonId = 255,
    cullMode = material.doubleSided and "none" or "back",
  }
end

-- Draw items in the MapRenderer item shape, one per definition mesh, with
-- the current pose. `renders` maps mesh id -> built render mesh (love Mesh
-- in production; any object in pure tests). A mesh whose node is hidden by
-- the current pose is omitted. When the pose state is nil (a nitro-backed
-- instance the backend did not evaluate), meshes render at their bind
-- placement under the instance transform.
function ModelInstance:drawItems(renders)
  assert(type(renders) == "table", "drawItems requires a mesh render table")
  local items = {}
  local pose = self.poseState
  for _, mesh in ipairs(self.definition.meshes) do
    if not (pose and pose.nodeVisible[mesh.nodeIndex] == false) then
      local nodeMatrix = identityMatrix()
      if pose and pose.nodeMatrices[mesh.nodeIndex] then
        nodeMatrix = pose.nodeMatrices[mesh.nodeIndex]
      end
      local transform = Matrix4.multiply(self.transform, nodeMatrix)
      local material = self:effectiveMaterial(mesh.materialIndex)
      items[#items + 1] = {
        mesh = renders[mesh.id],
        material = material,
        transform = transform,
        alphaClass = material.alphaClass,
        alphaCutoff = material.alphaCutoff,
        polygonAlpha = material.polygonAlpha,
        polygonMode = material.polygonMode,
        polygonId = material.polygonId,
        cullMode = material.cullMode,
        center = { transform[13], transform[14], transform[15] },
        submissionIndex = #items,
        billboardBase = nil,
      }
    end
  end
  return items
end

return ModelInstance
