-- ModelDefinition: the engine-native model IR assembled from the derived
-- model descriptors. Everything the runtime and gameplay touch -- nodes,
-- meshes, materials, animations -- lives here in one shape; the nitro backend
-- (the only producer) poses through the compiled transform program carried in
-- `backend`. The definition is nitro by construction: there is no
-- sourceBackend abstraction, and a record that still carries the removed key
-- is a stale-schema artifact rejected at the load boundary.
--
--   definition = ModelDefinition.new({
--     key = "outdoor:12:abcd...",
--     nodes = { { index, name?, translation, rotation, scale } },
--     meshes = { { id, nodeIndex, materialIndex, geometry? } },
--     materials = { { id, name?, baseColor, alphaMode, doubleSided, texture?,
--                     polygonAlpha?, texMtxMode?, texWidth?, texHeight?,
--                     srt?, variants? } },
--     animations = { <AnimationClip>, ... },
--     backend = nil,                    -- opaque backend payload, never
--                                       -- interpreted by engine APIs
--   })
--
-- Node convention: indices are zero-based and contiguous; parents precede
-- their children so pose evaluation is a single top-down pass. Mesh batches
-- are not part of the definition: geometry lives in content-addressed .g4mesh
-- assets referenced by `geometry` (the loader builds the render meshes and
-- per-mesh model-space centers). Animations are validated AnimationClips
-- whose semanticNames (e.g. "door.open") let gameplay address them without
-- source-format numbers.
--
-- Pure domain module: no love.

local Errors = require("libs.rom.src.Errors")
local AnimationClip = require("libs.engine.src.AnimationClip")

local ModelDefinition = {}
ModelDefinition.__index = ModelDefinition

ModelDefinition.ALPHA_MODES = { opaque = true, mask = true, blend = true }

-- The four DS base-material registers a material's optional `colors` block
-- may carry (the shape NsbmdDynamicModel.baseMaterial compiles them into).
-- The block is optional: static-path materials emit only a baseColor, and
-- the shared evaluator falls back to it per component.
local MATERIAL_COLOR_CHANNELS = { diffuse = true, ambient = true, specular = true, emission = true }

-- The polygon draw fields MapAssetCompiler emits on every dynamic batch
-- record. A nitro-dynamic descriptor missing any of them is malformed
-- generated data; positionSource/transformMode are not mandatory (the
-- billboard batch in the corpus legitimately omits positionSource).
local DESCRIPTOR_DRAW_STATE_FIELDS = {
  "cullMode",
  "polygonMode",
  "polygonId",
  "translucentDepthWrite",
  "depthEqual",
  "polygonAlpha",
  "lightMask",
}

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
  local byId = {}
  for i, mesh in ipairs(meshes) do
    if type(mesh.id) ~= "string" or #mesh.id == 0 then
      Errors.raise("MODEL_DEF_MESH_NO_ID", "mesh " .. i .. " requires a non-empty id", {})
    end
    if byId[mesh.id] then
      Errors.raise("MODEL_DEF_DUPLICATE_MESH", "model has two meshes named " .. mesh.id, { meshId = mesh.id })
    end
    byId[mesh.id] = true
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
    -- Geometry references a .g4mesh path; a mesh carrying an embedded
    -- batch fails loudly, with or without a geometry path.
    if mesh.batch ~= nil then
      Errors.raise(
        "MODEL_DEF_MESH_EMBEDDED_BATCH",
        "mesh " .. mesh.id .. " carries an embedded batch; geometry must be a .g4mesh path",
        { meshId = mesh.id }
      )
    end
    if not (type(mesh.geometry) == "string" and #mesh.geometry > 0) then
      Errors.raise(
        "MODEL_DEF_MESH_NO_GEOMETRY",
        "mesh " .. mesh.id .. " requires a geometry path",
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
    -- The optional colors block: the four DS base-material registers the
    -- dynamic compiler emits, each a { r, g, b } integer triple in 0..255.
    -- Records without the block (the static path) are the shared evaluator's
    -- baseColor-fallback case, so the block is optional but strictly shaped
    -- when present.
    if material.colors ~= nil then
      if type(material.colors) ~= "table" then
        Errors.raise(
          "MODEL_DEF_BAD_MATERIAL_COLORS",
          "material " .. material.id .. " colors must be a table or nil",
          { materialIndex = material.id }
        )
      end
      for name, color in pairs(material.colors) do
        if not MATERIAL_COLOR_CHANNELS[name] then
          Errors.raise(
            "MODEL_DEF_BAD_MATERIAL_COLORS",
            "material " .. material.id .. " colors carries an unknown channel " .. tostring(name),
            { materialIndex = material.id, channel = name }
          )
        end
        if
          type(color) ~= "table"
          or not isInteger(color.r)
          or not isInteger(color.g)
          or not isInteger(color.b)
          or color.r < 0
          or color.r > 255
          or color.g < 0
          or color.g > 255
          or color.b < 0
          or color.b > 255
        then
          Errors.raise(
            "MODEL_DEF_BAD_MATERIAL_COLORS",
            "material " .. material.id .. " colors." .. name .. " must be { r, g, b } integers in 0..255",
            { materialIndex = material.id, channel = name }
          )
        end
      end
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

-- Every clip must be a real AnimationClip record: an animation addressed by
-- name or semantic must satisfy the whole playback contract, not merely
-- carry an id.
local function validateAnimations(animations)
  for _, clip in ipairs(animations) do
    if
      type(clip) ~= "table"
      or type(clip.id) ~= "string"
      or type(clip.name) ~= "string"
      or not AnimationClip.CATEGORIES[clip.category]
      or not (isInteger(clip.frameCount) and clip.frameCount >= 1)
      or type(clip.tracks) ~= "table"
      or #clip.tracks == 0
    then
      Errors.raise("MODEL_DEF_BAD_ANIMATION", "animations must be AnimationClip values", {})
    end
  end
end

function ModelDefinition.new(definition)
  assert(type(definition) == "table", "ModelDefinition.new requires a table")
  if type(definition.key) ~= "string" or #definition.key == 0 then
    Errors.raise("MODEL_DEF_NO_KEY", "model definition requires a non-empty key", {})
  end
  -- The sourceBackend abstraction is cut: the definition is nitro by
  -- construction, so the key is not part of the definition record. A record
  -- that still carries it is a stale-schema artifact and fails loudly at the
  -- load boundary.
  if definition.sourceBackend ~= nil then
    Errors.raise(
      "MODEL_DEF_BAD_SOURCE_BACKEND",
      "sourceBackend is not part of the model definition record; a definition is nitro by construction",
      { sourceBackend = definition.sourceBackend }
    )
  end
  if type(definition.nodes) ~= "table" or #definition.nodes == 0 then
    Errors.raise("MODEL_DEF_NO_NODES", "model definition requires at least one node", {})
  end
  if type(definition.meshes) ~= "table" or #definition.meshes == 0 then
    Errors.raise("MODEL_DEF_NO_MESHES", "model definition requires a meshes list", {})
  end
  if type(definition.materials) ~= "table" or #definition.materials == 0 then
    Errors.raise("MODEL_DEF_NO_MATERIALS", "model definition requires a materials list", {})
  end
  if definition.animations ~= nil and type(definition.animations) ~= "table" then
    Errors.raise("MODEL_DEF_BAD_ANIMATIONS", "animations must be a table or nil", {})
  end
  if definition.backend ~= nil and type(definition.backend) ~= "table" then
    Errors.raise("MODEL_DEF_BAD_BACKEND", "backend payload must be a table or nil", {})
  end

  validateNodes(definition.nodes)
  validateMeshes(definition.meshes, #definition.nodes, #definition.materials)
  validateMaterials(definition.materials)
  if definition.animations then
    validateAnimations(definition.animations)
  end

  -- Semantic animation lookup: by clip name first, then by any semantic role
  -- (e.g. "door.open"). A role mapped twice is an authoring error, and a
  -- clip name colliding with another clip's semantic role is ambiguous --
  -- both raise rather than making lookup precedence significant.
  local byName, bySemantic = {}, {}
  for _, clip in ipairs(definition.animations or {}) do
    if byName[clip.name] then
      Errors.raise(
        "MODEL_DEF_DUPLICATE_ANIMATION",
        "model " .. definition.key .. " has two clips named " .. clip.name,
        { name = clip.name }
      )
    end
    byName[clip.name] = clip
  end
  for _, clip in ipairs(definition.animations or {}) do
    for _, semantic in ipairs(clip.semanticNames or {}) do
      if bySemantic[semantic] then
        Errors.raise(
          "MODEL_DEF_DUPLICATE_SEMANTIC",
          "model " .. definition.key .. " maps role " .. semantic .. " twice",
          { semantic = semantic, name = clip.name }
        )
      end
      if byName[semantic] then
        Errors.raise(
          "MODEL_DEF_NAME_SEMANTIC_COLLISION",
          "model " .. definition.key .. " clip name " .. semantic .. " collides with a semantic role",
          { semantic = semantic, name = clip.name }
        )
      end
      bySemantic[semantic] = clip
    end
  end

  local self = setmetatable({
    key = definition.key,
    nodes = definition.nodes,
    meshes = definition.meshes,
    materials = definition.materials,
    animations = definition.animations or {},
    backend = definition.backend,
    animationByName = byName,
    animationBySemantic = bySemantic,
    bindings = {},
  }, ModelDefinition)

  -- The per-clip binding is resolved once, at assembly: the material-index
  -- -> track-index mapping the evaluators consume is precomputed here, never
  -- per frame. A clip played later outside the animations list (a test
  -- fixture) computes its binding on first access and caches it, so the
  -- record identity is stable either way.
  for _, clip in ipairs(self.animations) do
    self:binding(clip)
  end

  return self
end

-- Resolve a clip by name or semantic role (e.g. "door.open"), or nil.
function ModelDefinition:animation(nameOrSemantic)
  return self.animationByName[nameOrSemantic] or self.animationBySemantic[nameOrSemantic]
end

-- The model node for a node index, or nil.
function ModelDefinition:node(index)
  return self.nodes[index + 1]
end

-- Assemble a ModelDefinition from a serialized nitro model descriptor (the
-- cache form MapAssetCompiler writes):
--
--   desc = {
--     schema, key, memberId,
--     kind = "nitro-dynamic",
--     dynamic = {
--       nodes = <transform-program node records>,
--       transformProgram = <the compiled SBC program>,
--       batches = <dynamic batch records referencing .g4mesh paths>,
--     },
--     materials = { ... },   -- base material records (texture paths etc.)
--     animations = { ... },  -- compiled nitro clips
--   }
--
-- The definition's nodes are the program's bind SRTs (contiguous,
-- zero-based); the nitro backend poses through the program, never through
-- the IR nodes, which exist for the shared validation, visibility, and
-- diagnostics. MapSceneLoader assembles this so the runtime and the tests
-- share one assembly; it also stamps each mesh's model-space `center` from
-- the decoded geometry.
function ModelDefinition.fromNitroDescriptor(desc, opts)
  assert(type(desc) == "table" and desc.dynamic ~= nil, "fromNitroDescriptor requires a dynamic model descriptor")
  opts = opts or {}
  -- The descriptor is the load boundary for generated nitro models: the
  -- mandatory fields are required, never defaulted. The loader supplies the
  -- key through opts when it knows the model key.
  local key = opts.key or desc.key
  if not key then
    Errors.raise("NITRO_DESC_NO_KEY", "model descriptor requires a key (desc.key or opts.key)", {})
  end
  if type(desc.materials) ~= "table" or #desc.materials == 0 then
    Errors.raise("NITRO_DESC_NO_MATERIALS", "model descriptor requires a non-empty materials list", {})
  end
  if type(desc.animations) ~= "table" or #desc.animations == 0 then
    Errors.raise("NITRO_DESC_NO_ANIMATIONS", "model descriptor requires a non-empty animations list", {})
  end
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
    -- Geometry is a .g4mesh path in the serialized shape; an embedded batch
    -- is a stale fixture artifact, not a loadable model.
    if mesh.batch ~= nil then
      Errors.raise(
        "MODEL_DEF_MESH_EMBEDDED_BATCH",
        "descriptor batch " .. tostring(mesh.id) .. " carries an embedded batch; geometry must be a .g4mesh path",
        { meshId = mesh.id }
      )
    end
    -- The per-segment polygon draw state is compiled by our own compiler, so
    -- a record missing any field is malformed generated data, not a default.
    for _, field in ipairs(DESCRIPTOR_DRAW_STATE_FIELDS) do
      if mesh[field] == nil then
        Errors.raise(
          "NITRO_DESC_BAD_DRAW_STATE",
          "descriptor batch " .. tostring(mesh.id) .. " is missing the " .. field .. " draw state",
          { meshId = mesh.id, field = field }
        )
      end
    end
    local record = {
      id = mesh.id,
      nodeIndex = mesh.nodeIndex,
      materialIndex = mesh.materialIndex,
    }
    if mesh.geometry then
      record.geometry = mesh.geometry
    end
    meshes[#meshes + 1] = record
    local backendRecord = {
      drawIndex = mesh.drawIndex,
      positionSource = mesh.positionSource,
      transformMode = mesh.transformMode,
      cullMode = mesh.cullMode,
      polygonMode = mesh.polygonMode,
      polygonId = mesh.polygonId,
      lightMask = mesh.lightMask,
      translucentDepthWrite = mesh.translucentDepthWrite,
      depthEqual = mesh.depthEqual,
      polygonAlpha = mesh.polygonAlpha,
    }
    -- A batch whose run straddled a mid-run matrix boundary carries the
    -- per-vertex provenance (the leading vertices resolve under the
    -- pre-boundary source at draw time); without it the batch is fully
    -- owned by its own positionSource.
    if mesh.straddle then
      backendRecord.straddle = mesh.straddle
    end
    backendMeshes[mesh.id] = backendRecord
  end
  return ModelDefinition.new({
    key = key,
    nodes = nodes,
    meshes = meshes,
    materials = desc.materials,
    animations = desc.animations,
    backend = {
      program = program,
      meshes = backendMeshes,
    },
  })
end

-- The precomputed binding record of `clip` over this definition: the record
-- is built once at assembly (or on first access) and reused by every play of
-- the clip. Joint clip targets are node indices and map to themselves (nodes
-- are contiguous by contract); material clip targets are material names and
-- map to the material's id. A material clip additionally carries
-- `trackByMaterial`: material index -> track index, so the material
-- evaluator reads the track in O(1) instead of rescanning tracks by name.
-- Targets with no model element are omitted, matching Nitro's permissive
-- binding; a binding whose map resolves nothing makes attach/play raise its
-- zero-targets diagnostic.
function ModelDefinition:binding(clip)
  local record = self.bindings[clip]
  if not record then
    local map = {}
    local trackByMaterial
    if clip.category == "joint" then
      for _, track in ipairs(clip.tracks) do
        local target = track.target
        if type(target) == "number" and self:node(target) then
          map[target] = target
        end
      end
    elseif clip.category == "material" then
      trackByMaterial = {}
      for i, track in ipairs(clip.tracks) do
        for j, material in ipairs(self.materials) do
          if material.name == track.target then
            map[track.target] = material.id
            trackByMaterial[material.id] = i - 1
            break
          end
        end
      end
    end
    record = {
      map = map,
      trackByMaterial = trackByMaterial,
    }
    self.bindings[clip] = record
  end
  return record
end

return ModelDefinition
