-- ModelInstance: the per-model runtime object above the pose backend. An
-- instance owns the placement transform, the animation state
-- (ModelAnimationState), the per-instance material state, and the last
-- evaluated pose; it is the only animation-facing API gameplay touches.
-- Nothing here knows NSBCA, NARC, SBC, matrix slots, or Nitro animation
-- resource indices -- those live in the compiled transform program behind
-- NitroPoseBackend.
--
-- Usage per frame: instance:updateFixed() advances every attachment player,
-- instance:evaluatePose() recomputes the pose state through the nitro
-- backend, then drawItems(renderMeshesById) produces draw items in the
-- production renderer's shape (the same item contract MapRenderer consumes
-- for map/building draws). drawItems also re-evaluates the effective material
-- state from the material attachments -- UV transforms, pattern variants,
-- animated colors, and the recomputed render classification -- so the item
-- contract always reflects the current frame. `renderMeshesById` supplies
-- the built mesh per mesh id (the caller builds love meshes from the
-- definition's referenced .g4mesh geometry); drawItems itself stays pure so
-- pose and item math are testable without graphics. An optional
-- `resolveImage` callback (opts.resolveImage) maps a texture key to the
-- caller's image object; without one items draw untextured.
--
-- The definition and its clips are immutable and shared; materialState is
-- the instance's own map, so two instances of one model can animate at
-- different frames and with different material overrides. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelAnimationState = require("libs.engine.src.ModelAnimationState")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local NitroPoseBackend = require("libs.engine.src.NitroPoseBackend")
local PoseContract = require("libs.engine.src.PoseContract")
local MaterialEvaluator = require("libs.engine.src.MaterialEvaluator")
local AlphaClassifier = require("libs.engine.src.AlphaClassifier")

---@class MaterialRGB
---@field r integer
---@field g integer
---@field b integer

---@class MaterialColorComponents
---@field diffuse MaterialRGB
---@field ambient MaterialRGB
---@field specular MaterialRGB
---@field emission MaterialRGB

---@class MaterialInstanceState
---@field texture string|nil
---@field texWidth integer|nil
---@field texHeight integer|nil
---@field colors MaterialColorComponents
---@field polygonAlpha integer
---@field texMatrix number[]
---@field alphaClass string|nil

---@class ModelInstance
---@field definition table
---@field transform number[]
---@field animationState table
---@field materialState { [integer]: MaterialInstanceState }
---@field poseState PoseState|nil
---@field renderMeshesById table|nil -- caller-built render meshes per mesh id
---@field resolveImage fun(key: string): any|nil
---@field timeOfDayPlan table|nil -- band plan the scene loader attaches (TimeOfDayProps.plan)
local ModelInstance = {}
ModelInstance.__index = ModelInstance

-- Fragment alpha cutoff for cutout materials; the same value the renderer
-- uses when an item carries no explicit cutoff (MapRenderer.CUTOUT_EPSILON).
local CUTOUT_EPSILON = 0.5 / 255

-- alphaMode -> the renderer's render-pass class (the material contract).
local ALPHA_CLASS = {
  opaque = "opaque",
  mask = "cutout",
  blend = "translucent",
}

local function identityMatrix()
  return Matrix4.identity()
end

local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

-- The base material state with no animation: the definition's texture and
-- colors, the static SRT matrix (the evaluator builds it), and the alpha
-- class from the texture's alpha usage when the record carries texture
-- metadata, else the model contract's alphaMode.
local function baseMaterialState(definition, material)
  local state = {
    texture = material.texture,
    texWidth = material.texWidth,
    texHeight = material.texHeight,
    colors = { r = 255, g = 255, b = 255, a = 255 },
    polygonAlpha = material.polygonAlpha or 31,
    texMatrix = IDENTITY_TEX_MATRIX,
  }
  if material.textureFormat ~= nil then
    state.alphaClass = AlphaClassifier.classify(state.polygonAlpha, material.textureFormat, material.alphaUsage)
  else
    state.alphaClass = ALPHA_CLASS[material.alphaMode] or "opaque"
  end
  return state
end

---@return ModelInstance
function ModelInstance.new(definition, opts)
  assert(type(definition) == "table" and definition.key ~= nil, "ModelInstance.new requires a ModelDefinition")
  opts = opts or {}
  local transform = opts.transform or identityMatrix()
  assert(type(transform) == "table" and #transform == 16, "instance transform must be a 16-element column-major matrix")

  local materialState = {}
  for _, material in ipairs(definition.materials) do
    materialState[material.id] = baseMaterialState(definition, material)
  end

  return setmetatable({
    definition = definition,
    transform = transform,
    animationState = ModelAnimationState.new(definition),
    materialState = materialState,
    poseState = nil,
    resolveImage = opts.resolveImage,
  }, ModelInstance)
end

-- Advance every attachment player by one fixed step.
function ModelInstance:updateFixed()
  self.animationState:updateFixed()
end

-- Recompute the pose state from the current animation state through the
-- definition's nitro pose backend. Returns the PoseState. Raises a
-- structured error when the backend cannot evaluate (no silent fallback).
---@return PoseState
function ModelInstance:evaluatePose()
  self.poseState = NitroPoseBackend.evaluate(self)
  return self.poseState
end

-- Start playing a clip, resolved by name or semantic role (e.g.
-- "door.open"). The binding comes from the definition's precomputed record;
-- player setup happens here, once per play, never per frame. `opts` passes
-- through to the attachment: priority, ratioFx, loopMode. Reverse playback
-- is cut: there is no direction option and a one-shot always plays forward
-- from 0. Returns the LIVE attachment as the handle (a plain table carrying
-- clip/binding/player/priority/ratioFx) for stop() -- there is no token
-- layer. Every play attaches an independent player, so several clips can run
-- simultaneously. A clip that binds no model element raises
-- ANIM_STATE_ZERO_BINDING and attaches nothing.
function ModelInstance:play(nameOrSemantic, opts)
  local clip = self.definition:animation(nameOrSemantic)
  if not clip then
    Errors.raise(
      "ANIM_INSTANCE_UNKNOWN_ANIMATION",
      "model " .. self.definition.key .. " has no clip named " .. tostring(nameOrSemantic),
      { modelKey = self.definition.key, name = nameOrSemantic }
    )
  end
  opts = opts or {}
  if opts.loopMode then
    assert(AnimationPlayer.LOOP_MODES[opts.loopMode], "loopMode must be loop or once")
  end
  assert(opts.direction == nil, "direction is not a play option: reverse playback is cut")

  local player = opts.player or AnimationPlayer.new(clip)
  if opts.loopMode then
    player.loopMode = opts.loopMode
  end

  return self.animationState:attach(clip, {
    player = player,
    priority = opts.priority,
    ratioFx = opts.ratioFx,
  })
end

-- Stop playing clips: by attachment handle (exactly that attachment), or by
-- name/semantic role (every play of the matching clip). Returns the number
-- of attachments removed.
function ModelInstance:stop(nameOrHandle)
  if type(nameOrHandle) == "table" then
    return self.animationState:detach(nameOrHandle)
  end
  local removed = 0
  local state = self.animationState
  for _, category in ipairs(ModelAnimationState.GROUPS) do
    for _, attachment in ipairs(state:attachments(category)) do
      local clip = attachment.clip
      local matchesName = clip.name == nameOrHandle or clip.id == nameOrHandle
      for _, semantic in ipairs(clip.semanticNames or {}) do
        if semantic == nameOrHandle then
          matchesName = true
        end
      end
      if matchesName then
        state:detach(attachment)
        removed = removed + 1
      end
    end
  end
  return removed
end

-- Recompute the effective material state from the material attachments.
-- Runs inside drawItems; call it directly to inspect the state without
-- drawing. With no attachments the evaluator still runs: the static SRT
-- matrix and the base texture's alpha classification are part of the
-- effective state.
function ModelInstance:evaluateMaterials()
  MaterialEvaluator.evaluate(self.definition, self.animationState:attachments("material"), self.materialState)
end

-- The effective render material record for a material index: definition
-- properties plus this instance's evaluated state. Never mutates the
-- definition. The texture image is resolved through the instance's
-- resolveImage callback (nil without one); the UV transform matrix is the
-- evaluator's normalized 3x3. The polygon draw state (cull mode, polygon
-- mode/id, depth flags) is per draw segment and lives on the mesh records,
-- not here.
function ModelInstance:effectiveMaterial(materialIndex)
  local material = assert(
    self.definition.materials[materialIndex + 1],
    "material index " .. tostring(materialIndex) .. " out of range"
  )
  local state = self.materialState[materialIndex]
  local colors = state and state.colors
  local function component(name, fallback)
    local c = colors and colors[name]
    if c then
      return { c.r / 255, c.g / 255, c.b / 255 }
    end
    local base = material.baseColor or { r = 255, g = 255, b = 255, a = 255 }
    if name == "emission" then
      return fallback
    end
    return { base.r / 255, base.g / 255, base.b / 255 }
  end
  local image
  if state and state.texture and self.resolveImage then
    image = self.resolveImage(state.texture)
  end
  local alphaClass = state and state.alphaClass or ALPHA_CLASS[material.alphaMode] or "opaque"
  return {
    image = image,
    texMatrix = state and state.texMatrix or IDENTITY_TEX_MATRIX,
    matDiffuse = component("diffuse"),
    matAmbient = component("ambient"),
    matSpecular = component("specular"),
    matEmission = component("emission", { 0, 0, 0 }),
    alphaClass = alphaClass,
    alphaCutoff = alphaClass == "cutout" and CUTOUT_EPSILON or nil,
    polygonAlpha = (state and state.polygonAlpha or 31) / 31,
  }
end

-- A draw item in the MapRenderer item shape (the contract MapRenderer
-- consumes for map/building draws).
---@class ModelDrawItem
---@field mesh table -- built render mesh for the item's mesh id
---@field material table -- effective material record
---@field transform number[] -- 16-element column-major matrix
---@field alphaClass string
---@field alphaCutoff number|nil
---@field polygonAlpha number
---@field polygonMode string
---@field polygonId integer
---@field cullMode string
---@field translucentDepthWrite boolean
---@field depthEqual boolean
---@field center number[] -- model-space center, transformed by the render queue
---@field submissionIndex integer|nil -- assigned by the scene flattening pass
---@field billboardBase number[]|nil

-- Draw items in the MapRenderer item shape, one per definition mesh, with
-- the current pose. `renderMeshesById` maps mesh id -> built render mesh
-- (love Mesh in production; any object in pure tests). A mesh whose node is
-- hidden by the current pose is omitted. Before the first pose evaluation
-- meshes render at their bind placement under the instance transform.
--
-- Nitro-backed definitions carry per-mesh draw records in the pose
-- (PoseState.drawMatrices): a Nitro draw is not one node matrix, so those
-- records -- resolved from the transform program -- replace the node-matrix
-- path, and the polygon draw state compiled per segment (cull mode, polygon
-- mode/id, depth flags) rides on the item. A billboard draw's baked geometry
-- takes the camera-facing matrix rebuilt from its captured base
-- (MapRenderer), exactly like the static building path. The center is the
-- mesh's model-space bounding-box center (stamped by the loader); the
-- render queue transforms it once by the item transform.
---@return ModelDrawItem[]
function ModelInstance:drawItems(renderMeshesById)
  assert(type(renderMeshesById) == "table", "drawItems requires a mesh render table")
  self:evaluateMaterials()
  local items = {}
  local pose = self.poseState
  local backendMeshes = self.definition.backend and self.definition.backend.meshes or {}
  for _, mesh in ipairs(self.definition.meshes) do
    if not (pose and pose.nodeVisible[mesh.nodeIndex] == false) then
      ---@type PoseDrawMatrix|nil
      local draw = pose and pose.drawMatrices and pose.drawMatrices[mesh.id]
      local transform, billboardBase
      if draw then
        if draw.transformMode == PoseContract.BILLBOARD then
          billboardBase = Matrix4.multiply(self.transform, draw.baseTransform)
          transform = billboardBase
        else
          transform = Matrix4.multiply(self.transform, draw.position)
        end
      else
        local nodeMatrix = identityMatrix()
        if pose and pose.nodeMatrices[mesh.nodeIndex] then
          nodeMatrix = pose.nodeMatrices[mesh.nodeIndex]
        end
        transform = Matrix4.multiply(self.transform, nodeMatrix)
      end
      local meshState = backendMeshes[mesh.id]
      local material = self:effectiveMaterial(mesh.materialIndex)
      items[#items + 1] = {
        mesh = renderMeshesById[mesh.id],
        material = material,
        transform = transform,
        billboardBase = billboardBase,
        alphaClass = material.alphaClass,
        alphaCutoff = material.alphaCutoff,
        polygonAlpha = material.polygonAlpha,
        polygonMode = meshState and meshState.polygonMode or "modulation",
        polygonId = meshState and meshState.polygonId or 0,
        cullMode = meshState and meshState.cullMode or "back",
        translucentDepthWrite = meshState and meshState.translucentDepthWrite or false,
        depthEqual = meshState and meshState.depthEqual or false,
        center = mesh.center or { 0, 0, 0 },
      }
    end
  end
  return items
end

return ModelInstance
