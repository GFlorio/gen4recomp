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
--     doorSoundType = integer|nil,
--     backend = nil,                    -- opaque backend payload, never
--                                       -- interpreted by engine APIs
--   })
--
-- Node convention: indices are zero-based and contiguous; parents precede
-- their children so pose evaluation is a single top-down pass. Mesh batches
-- are not part of the definition: geometry lives in content-addressed .g4mesh
-- assets referenced by `geometry` (the loader builds the render meshes and
-- stamps the per-mesh model-space centers). Animations are AnimationClips
-- whose semanticNames (e.g. "door.open") let gameplay address them without
-- source-format numbers.
--
-- The serialized record is validated once, at the artifact gate
-- (ModelAsset.validate), so this constructor does not re-parse the
-- descriptor shape: it checks the IR-level requirements (the required lists,
-- the stale-schema sourceBackend key) and nothing the gate already owns.
--
-- Pure domain module: no love.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local PolygonState = require("libs.assets.src.PolygonState")
local AnimationClip = require("libs.assets.src.AnimationClip")

local ModelDefinition = {}
ModelDefinition.__index = ModelDefinition

function ModelDefinition.new(definition)
  assert(type(definition) == "table", "ModelDefinition.new requires a table")
  if type(definition.key) ~= "string" or #definition.key == 0 then
    Errors.raise(FieldErrors.MODEL_DEF_NO_KEY, "model definition requires a non-empty key", {})
  end
  -- A record that still carries `sourceBackend` is a stale-schema artifact;
  -- it fails loudly at the load boundary.
  if definition.sourceBackend ~= nil then
    Errors.raise(
      FieldErrors.MODEL_DEF_BAD_SOURCE_BACKEND,
      "sourceBackend is not part of the model definition record; a definition is nitro by construction",
      { sourceBackend = definition.sourceBackend }
    )
  end
  if type(definition.nodes) ~= "table" or #definition.nodes == 0 then
    Errors.raise(FieldErrors.MODEL_DEF_NO_NODES, "model definition requires at least one node", {})
  end
  if type(definition.meshes) ~= "table" or #definition.meshes == 0 then
    Errors.raise(FieldErrors.MODEL_DEF_NO_MESHES, "model definition requires a meshes list", {})
  end
  if type(definition.materials) ~= "table" or #definition.materials == 0 then
    Errors.raise(FieldErrors.MODEL_DEF_NO_MATERIALS, "model definition requires a materials list", {})
  end
  if type(definition.animations) ~= "table" then
    Errors.raise(FieldErrors.MODEL_DEF_BAD_ANIMATIONS, "animations must be a table", {})
  end
  if definition.backend ~= nil and type(definition.backend) ~= "table" then
    Errors.raise(FieldErrors.MODEL_DEF_BAD_BACKEND, "backend payload must be a table or nil", {})
  end

  -- Semantic animation lookup: by clip name first, then by any semantic role
  -- (e.g. "door.open"). A role mapped twice is an authoring error, and a
  -- clip name colliding with another clip's semantic role is ambiguous --
  -- both raise rather than making lookup precedence significant.
  local byName, bySemantic = {}, {}
  for _, clip in ipairs(definition.animations) do
    if byName[clip.name] then
      Errors.raise(
        FieldErrors.MODEL_DEF_DUPLICATE_ANIMATION,
        "model " .. definition.key .. " has two clips named " .. clip.name,
        { name = clip.name }
      )
    end
    byName[clip.name] = clip
  end
  for _, clip in ipairs(definition.animations) do
    for _, semantic in ipairs(clip.semanticNames) do
      if bySemantic[semantic] then
        Errors.raise(
          FieldErrors.MODEL_DEF_DUPLICATE_SEMANTIC,
          "model " .. definition.key .. " maps role " .. semantic .. " twice",
          { semantic = semantic, name = clip.name }
        )
      end
      if byName[semantic] then
        Errors.raise(
          FieldErrors.MODEL_DEF_NAME_SEMANTIC_COLLISION,
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
    animations = definition.animations,
    doorSoundType = definition.doorSoundType,
    backend = definition.backend,
    animationByName = byName,
    animationBySemantic = bySemantic,
    bindings = {},
  }, ModelDefinition)

  -- The per-clip binding is resolved once, at assembly: the material-index
  -- -> track-index mapping the evaluators consume is precomputed here, never
  -- per frame. A clip outside the animations list has no binding and is
  -- rejected on access (see binding()).
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
-- The descriptor is validated by the artifact gate (ModelAsset.validate)
-- before it reaches the runtime, so assembly copies the records without
-- re-checking their shape: batch draw state, material records, and clip
-- payloads are all gate-owned. The definition's nodes are the program's bind
-- SRTs (contiguous, zero-based); the nitro backend poses through the
-- program, never through the IR nodes, which exist for the shared
-- validation, visibility, and diagnostics. MapSceneLoader assembles this so
-- the runtime and the tests share one assembly; it also stamps each mesh's
-- model-space `center` from the decoded geometry.
function ModelDefinition.fromNitroDescriptor(desc, opts)
  assert(type(desc) == "table" and desc.dynamic ~= nil, "fromNitroDescriptor requires a dynamic model descriptor")
  opts = opts or {}
  -- The loader supplies the key through opts when it knows the model key.
  local key = opts.key or desc.key
  if not key then
    Errors.raise(FieldErrors.NITRO_DESC_NO_KEY, "model descriptor requires a key (desc.key or opts.key)", {})
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
    local record = {
      id = mesh.id,
      nodeIndex = mesh.nodeIndex,
      materialIndex = mesh.materialIndex,
      geometry = mesh.geometry,
    }
    meshes[#meshes + 1] = record
    -- The shared draw-state set rides on the backend record (complete: the
    -- gate requires every PolygonState field on every batch);
    -- positionSource/transformMode are not mandatory (the billboard batch
    -- in the corpus legitimately omits positionSource).
    local backendRecord = PolygonState.copy(mesh)
    backendRecord.drawIndex = mesh.drawIndex
    backendRecord.positionSource = mesh.positionSource
    backendRecord.transformMode = mesh.transformMode
    -- Preserve source-side matrix-boundary provenance in the compiled backend
    -- record; runtime presentation draws the resident batch as one mesh.
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
    doorSoundType = desc.doorSoundType,
    backend = {
      program = program,
      meshes = backendMeshes,
    },
  })
end

-- The precomputed binding record of `clip` over this definition: the record
-- is built once at assembly and reused by every play of the clip. Joint clip
-- targets are node indices and map to themselves (nodes are contiguous by
-- contract); material clip targets are material names and map to the
-- material's id. A material clip additionally carries `trackByMaterial`:
-- material index -> track index, so the material evaluator reads the track
-- in O(1) instead of rescanning tracks by name. Targets with no model
-- element are omitted, matching Nitro's permissive binding; a binding whose
-- map resolves nothing makes attach/play raise its zero-targets diagnostic.
-- A clip outside the animations list has no binding: the assembly loop
-- precomputes every in-list clip, so a miss here is a programming fault and
-- raises instead of lazily binding an unlisted clip.
function ModelDefinition:binding(clip)
  local record = self.bindings[clip]
  if not record then
    assert(
      clip and self.animationByName[clip.name] == clip,
      "clip "
        .. tostring(clip and clip.id)
        .. " is not in the animations list of model "
        .. self.key
        .. "; bindings are resolved at assembly"
    )
    local map = {}
    local trackByMaterial
    if clip.category == AnimationClip.CATEGORIES.joint then
      for _, track in ipairs(clip.tracks) do
        local target = track.target
        if type(target) == "number" and self:node(target) then
          map[target] = target
        end
      end
    elseif clip.category == AnimationClip.CATEGORIES.material then
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
