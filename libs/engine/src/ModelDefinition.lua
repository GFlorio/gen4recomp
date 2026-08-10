-- ModelDefinition: the engine-native, source-format-neutral model IR.
-- Everything the runtime and gameplay touch -- meshes, materials, nodes,
-- skins, animations -- lives here in one shape regardless of whether the
-- asset came from an NSBMD/NSBCA pair or a future Blender/GLB export. The
-- glTF mapping contract is documented in docs/model-ir.md; this module is
-- its Lua face.
--
--   definition = ModelDefinition.new({
--     key = "fixture:door",
--     sourceBackend = "nitro",        -- "nitro" | "generic"
--     nodes = { { index, name?, parentIndex?, translation, rotation, scale } },
--     meshes = { { id, name?, nodeIndex, materialIndex, batch } },
--     materials = { { id, name?, baseColor, alphaMode, doubleSided, texture?,
--                     polygonAlpha?, texMtxMode?, texWidth?, texHeight?,
--                     srt?, variants? } },
--     skins = { { id, joints, inverseBindMatrices } },
--     animations = { <AnimationClip>, ... },
--     backend = nil,                    -- opaque backend payload, never
--                                       -- interpreted by engine APIs
--     instanceMetadata = {},            -- passthrough instance metadata
--   })
--
-- Node convention: indices are zero-based and contiguous; parents precede
-- their children so pose evaluation is a single top-down pass. Local
-- transforms are TRS (translation {x,y,z}, 9-cell rotation, scale {x,y,z});
-- the generic backend composes local = T * R * S, the glTF convention.
-- Mesh batches use the MeshWriter vertex shape (see libs/assets/src/MeshWriter),
-- with joints/weights on vertices that skin. Animations are validated
-- AnimationClips whose semanticNames (e.g. "door.open") let gameplay address
-- them without source-format numbers.
--
-- Pure domain module: no love.

local Errors = require("libs.rom.src.Errors")
local AnimationClip = require("libs.engine.src.AnimationClip")

local ModelDefinition = {}
ModelDefinition.__index = ModelDefinition

ModelDefinition.SOURCE_BACKENDS = { nitro = true, generic = true }
ModelDefinition.ALPHA_MODES = { opaque = true, mask = true, blend = true }

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value)
  return type(value) == "number" and math.floor(value) == value
end

local function validateVec3(value, what)
  if
    type(value) ~= "table"
    or not isFiniteNumber(value.x)
    or not isFiniteNumber(value.y)
    or not isFiniteNumber(value.z)
  then
    Errors.raise("MODEL_DEF_BAD_TRANSFORM", "node " .. what .. " must be { x, y, z } finite numbers", { what = what })
  end
end

local function validateNodes(nodes)
  for i, node in ipairs(nodes) do
    local index = i - 1
    if node.index ~= index then
      Errors.raise(
        "MODEL_DEF_NODE_INDEX_MISMATCH",
        "nodes must be contiguous zero-based indices; node " .. i .. " has index " .. tostring(node.index),
        { nodeIndex = node.index, expected = index }
      )
    end
    if node.parentIndex ~= nil then
      if not isInteger(node.parentIndex) or node.parentIndex < 0 or node.parentIndex >= index then
        Errors.raise(
          "MODEL_DEF_BAD_PARENT",
          "node " .. index .. " parent must be an earlier node (parent-before-child order)",
          { nodeIndex = index, parentIndex = node.parentIndex }
        )
      end
    end
    validateVec3(node.translation, "translation of node " .. index)
    validateVec3(node.scale, "scale of node " .. index)
    if type(node.rotation) ~= "table" or #node.rotation ~= 9 then
      Errors.raise(
        "MODEL_DEF_BAD_ROTATION",
        "node " .. index .. " rotation must be a 9-cell matrix",
        { nodeIndex = index }
      )
    end
    for k = 1, 9 do
      if not isFiniteNumber(node.rotation[k]) then
        Errors.raise(
          "MODEL_DEF_BAD_ROTATION",
          "node " .. index .. " rotation cell " .. k .. " is not finite",
          { nodeIndex = index }
        )
      end
    end
  end
end

local function validateMeshes(meshes, nodeCount, materialCount)
  for i, mesh in ipairs(meshes) do
    if type(mesh.id) ~= "string" or #mesh.id == 0 then
      Errors.raise("MODEL_DEF_MESH_NO_ID", "mesh " .. i .. " requires a non-empty id", {})
    end
    if not (isInteger(mesh.nodeIndex) and mesh.nodeIndex >= 0 and mesh.nodeIndex < nodeCount) then
      Errors.raise(
        "MODEL_DEF_MESH_BAD_NODE",
        "mesh " .. mesh.id .. " references an unknown node index",
        { meshId = mesh.id, nodeIndex = mesh.nodeIndex }
      )
    end
    if not (isInteger(mesh.materialIndex) and mesh.materialIndex >= 0 and mesh.materialIndex < materialCount) then
      Errors.raise(
        "MODEL_DEF_MESH_BAD_MATERIAL",
        "mesh " .. mesh.id .. " references an unknown material index",
        { meshId = mesh.id, materialIndex = mesh.materialIndex }
      )
    end
    if type(mesh.batch) ~= "table" or type(mesh.batch.vertices) ~= "table" then
      Errors.raise(
        "MODEL_DEF_MESH_NO_BATCH",
        "mesh " .. mesh.id .. " requires a batch with vertices",
        { meshId = mesh.id }
      )
    end
  end
end

local function validateMaterials(materials)
  for i, material in ipairs(materials) do
    if not isInteger(material.id) or material.id ~= i - 1 then
      Errors.raise(
        "MODEL_DEF_MATERIAL_INDEX_MISMATCH",
        "materials must be contiguous zero-based indices; material " .. i .. " has id " .. tostring(material.id),
        {}
      )
    end
    if not ModelDefinition.ALPHA_MODES[material.alphaMode] then
      Errors.raise(
        "MODEL_DEF_BAD_ALPHA_MODE",
        "material " .. material.id .. " alphaMode must be opaque, mask, or blend",
        { materialIndex = material.id, alphaMode = material.alphaMode }
      )
    end
    local base = material.baseColor
    if
      type(base) ~= "table"
      or not isInteger(base.r)
      or not isInteger(base.g)
      or not isInteger(base.b)
      or not isInteger(base.a)
      or base.r < 0
      or base.r > 255
      or base.g < 0
      or base.g > 255
      or base.b < 0
      or base.b > 255
      or base.a < 0
      or base.a > 255
    then
      Errors.raise(
        "MODEL_DEF_BAD_BASE_COLOR",
        "material " .. material.id .. " baseColor must be { r, g, b, a } integers in 0..255",
        { materialIndex = material.id }
      )
    end
    if
      material.polygonAlpha ~= nil
      and (not isInteger(material.polygonAlpha) or material.polygonAlpha < 0 or material.polygonAlpha > 31)
    then
      Errors.raise(
        "MODEL_DEF_BAD_POLYGON_ALPHA",
        "material " .. material.id .. " polygonAlpha must be an integer in 0..31",
        { materialIndex = material.id }
      )
    end
    if
      material.texMtxMode ~= nil
      and (not isInteger(material.texMtxMode) or material.texMtxMode < 0 or material.texMtxMode > 3)
    then
      Errors.raise(
        "MODEL_DEF_BAD_TEXMTX_MODE",
        "material " .. material.id .. " texMtxMode must be 0..3",
        { materialIndex = material.id }
      )
    end
    -- Pattern-animation variants: one entry per (texture, palette) pair the
    -- model's pattern clips can select, keyed by the authoring name.
    if material.variants ~= nil then
      if type(material.variants) ~= "table" then
        Errors.raise(
          "MODEL_DEF_BAD_VARIANTS",
          "material " .. material.id .. " variants must be a table or nil",
          { materialIndex = material.id }
        )
      end
      local byName = {}
      for _, variant in ipairs(material.variants) do
        if type(variant.name) ~= "string" or #variant.name == 0 then
          Errors.raise(
            "MODEL_DEF_BAD_VARIANT_NAME",
            "material " .. material.id .. " has a variant without a name",
            { materialIndex = material.id }
          )
        end
        if byName[variant.name] then
          Errors.raise(
            "MODEL_DEF_DUPLICATE_VARIANT",
            "material " .. material.id .. " lists variant " .. variant.name .. " twice",
            { materialIndex = material.id, variant = variant.name }
          )
        end
        byName[variant.name] = true
        if variant.texture ~= nil and type(variant.texture) ~= "string" then
          Errors.raise(
            "MODEL_DEF_BAD_VARIANT_TEXTURE",
            "variant " .. variant.name .. " of material " .. material.id .. " has a non-string texture key",
            { materialIndex = material.id, variant = variant.name }
          )
        end
      end
    end
  end
end

local function validateSkins(skins, nodeCount)
  for i, skin in ipairs(skins) do
    if type(skin.id) ~= "string" or #skin.id == 0 then
      Errors.raise("MODEL_DEF_SKIN_NO_ID", "skin " .. i .. " requires a non-empty id", {})
    end
    if type(skin.joints) ~= "table" or #skin.joints == 0 then
      Errors.raise(
        "MODEL_DEF_SKIN_NO_JOINTS",
        "skin " .. skin.id .. " requires at least one joint",
        { skinId = skin.id }
      )
    end
    for _, joint in ipairs(skin.joints) do
      if not (isInteger(joint) and joint >= 0 and joint < nodeCount) then
        Errors.raise(
          "MODEL_DEF_SKIN_BAD_JOINT",
          "skin " .. skin.id .. " references an unknown joint",
          { skinId = skin.id, joint = joint }
        )
      end
    end
    if type(skin.inverseBindMatrices) ~= "table" then
      Errors.raise("MODEL_DEF_SKIN_NO_IBM", "skin " .. skin.id .. " requires inverseBindMatrices", { skinId = skin.id })
    end
    for _, joint in ipairs(skin.joints) do
      local m = skin.inverseBindMatrices[joint]
      if type(m) ~= "table" or #m ~= 16 then
        Errors.raise(
          "MODEL_DEF_SKIN_BAD_IBM",
          "skin " .. skin.id .. " joint " .. joint .. " needs a 16-element inverse bind matrix",
          { skinId = skin.id, joint = joint }
        )
      end
    end
  end
end

local function validateAnimations(animations)
  for _, clip in ipairs(animations) do
    if type(clip) ~= "table" or clip.id == nil then
      Errors.raise("MODEL_DEF_BAD_ANIMATION", "animations must be AnimationClip values", {})
    end
  end
end

function ModelDefinition.new(spec)
  assert(type(spec) == "table", "ModelDefinition.new requires a table")
  if type(spec.key) ~= "string" or #spec.key == 0 then
    Errors.raise("MODEL_DEF_NO_KEY", "model definition requires a non-empty key", {})
  end
  if not ModelDefinition.SOURCE_BACKENDS[spec.sourceBackend] then
    Errors.raise(
      "MODEL_DEF_BAD_SOURCE_BACKEND",
      "sourceBackend must be nitro or generic, got " .. tostring(spec.sourceBackend),
      {}
    )
  end
  if type(spec.nodes) ~= "table" or #spec.nodes == 0 then
    Errors.raise("MODEL_DEF_NO_NODES", "model definition requires at least one node", {})
  end
  if type(spec.meshes) ~= "table" then
    Errors.raise("MODEL_DEF_NO_MESHES", "model definition requires a meshes list", {})
  end
  if type(spec.materials) ~= "table" then
    Errors.raise("MODEL_DEF_NO_MATERIALS", "model definition requires a materials list", {})
  end
  if spec.skins ~= nil and type(spec.skins) ~= "table" then
    Errors.raise("MODEL_DEF_BAD_SKINS", "skins must be a table or nil", {})
  end
  if spec.animations ~= nil and type(spec.animations) ~= "table" then
    Errors.raise("MODEL_DEF_BAD_ANIMATIONS", "animations must be a table or nil", {})
  end
  if spec.backend ~= nil and type(spec.backend) ~= "table" then
    Errors.raise("MODEL_DEF_BAD_BACKEND", "backend payload must be a table or nil", {})
  end
  if spec.instanceMetadata ~= nil and type(spec.instanceMetadata) ~= "table" then
    Errors.raise("MODEL_DEF_BAD_INSTANCE_METADATA", "instanceMetadata must be a table or nil", {})
  end

  validateNodes(spec.nodes)
  validateMeshes(spec.meshes, #spec.nodes, #spec.materials)
  validateMaterials(spec.materials)
  if spec.skins then
    validateSkins(spec.skins, #spec.nodes)
  end
  if spec.animations then
    validateAnimations(spec.animations)
  end

  -- Semantic animation lookup: by clip name first, then by any semantic role
  -- (e.g. "door.open"). A role mapped twice is an authoring error.
  local byName, bySemantic = {}, {}
  for _, clip in ipairs(spec.animations or {}) do
    if byName[clip.name] then
      Errors.raise(
        "MODEL_DEF_DUPLICATE_ANIMATION",
        "model " .. spec.key .. " has two clips named " .. clip.name,
        { name = clip.name }
      )
    end
    byName[clip.name] = clip
    for _, semantic in ipairs(clip.semanticNames or {}) do
      if bySemantic[semantic] then
        Errors.raise(
          "MODEL_DEF_DUPLICATE_SEMANTIC",
          "model " .. spec.key .. " maps role " .. semantic .. " twice",
          { semantic = semantic, name = clip.name }
        )
      end
      bySemantic[semantic] = clip
    end
  end

  return setmetatable({
    key = spec.key,
    sourceBackend = spec.sourceBackend,
    nodes = spec.nodes,
    meshes = spec.meshes,
    materials = spec.materials,
    skins = spec.skins or {},
    animations = spec.animations or {},
    backend = spec.backend,
    instanceMetadata = spec.instanceMetadata or {},
    animationByName = byName,
    animationBySemantic = bySemantic,
  }, ModelDefinition)
end

-- Resolve a clip by name or semantic role (e.g. "door.open"), or nil.
function ModelDefinition:animation(nameOrSemantic)
  return self.animationByName[nameOrSemantic] or self.animationBySemantic[nameOrSemantic]
end

-- All clip names of the definition, in declaration order.
function ModelDefinition:animationNames()
  local out = {}
  for _, clip in ipairs(self.animations) do
    out[#out + 1] = clip.name
  end
  return out
end

-- The model node for a node index, or nil.
function ModelDefinition:node(index)
  return self.nodes[index + 1]
end

-- Assemble a ModelDefinition from a serialized nitro model descriptor (the
-- cache form MapAssetCompiler writes; the dynamic half of the spec section
-- 40 shape):
--
--   desc = {
--     key, memberId,
--     backend = "nitro",
--     dynamic = {
--       nodes = <transform-program node records>,
--       transformProgram = <the compiled SBC program>,
--       batches = <MeshCompiler.compileDynamic output>,
--     },
--     materials = { ... },   -- base material records (texture paths etc.)
--     animations = { ... },  -- compiled nitro clips
--   }
--
-- The definition's nodes are the program's bind SRTs (contiguous,
-- zero-based); the nitro backend poses through the program, never through
-- the IR nodes, which exist for the shared validation, visibility, and
-- diagnostics. The digest-side NsbmdDynamicModel.toDefinition delegates
-- here so the runtime and the tests share one assembly.
function ModelDefinition.fromNitroDescriptor(desc, opts)
  assert(type(desc) == "table" and desc.dynamic ~= nil, "fromNitroDescriptor requires a dynamic model descriptor")
  opts = opts or {}
  local program = desc.dynamic.transformProgram
  local nodes = {}
  for i, node in ipairs(desc.dynamic.nodes) do
    nodes[#nodes + 1] = {
      index = i - 1,
      name = node.name,
      translation = node.translation,
      rotation = node.rotation,
      scale = node.scale,
    }
  end
  local meshes = {}
  local backendMeshes = {}
  for _, mesh in ipairs(desc.dynamic.batches) do
    meshes[#meshes + 1] = {
      id = mesh.id,
      nodeIndex = mesh.nodeIndex,
      materialIndex = mesh.materialIndex,
      batch = mesh.batch,
    }
    backendMeshes[mesh.id] = {
      drawIndex = mesh.drawIndex,
      positionSource = mesh.positionSource,
      transformMode = mesh.transformMode,
    }
  end
  return ModelDefinition.new({
    key = opts.key or desc.key or program.name or "nitro-model",
    sourceBackend = "nitro",
    nodes = nodes,
    meshes = meshes,
    materials = desc.materials or {},
    skins = {},
    animations = desc.animations or {},
    backend = {
      program = program,
      meshes = backendMeshes,
    },
  })
end

-- The loading-time binding map for `clip` over this definition: joint/
-- visibility clip targets are node indices and map to themselves (nodes are
-- contiguous by contract); material clip targets are material names and map
-- to the material's id. Targets with no model element are omitted, matching
-- Nitro's permissive binding; a map that resolves nothing makes
-- AnimationBinding.new raise its zero-targets diagnostic.
function ModelDefinition:bindingMap(clip)
  local map = {}
  if clip.category == "joint" or clip.category == "visibility" then
    for _, track in ipairs(clip.tracks) do
      local target = track.target
      if type(target) == "number" and self:node(target) then
        map[target] = target
      end
    end
  elseif clip.category == "material" then
    for _, track in ipairs(clip.tracks) do
      for i, material in ipairs(self.materials) do
        if material.name == track.target then
          map[track.target] = material.id
          break
        end
      end
    end
  end
  return map
end

return ModelDefinition
