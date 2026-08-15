-- ModelDefinition: the engine-native model IR -- assembly, semantic
-- animation resolution, and the loading-time binding maps a nitro descriptor
-- produces. The serialized descriptor shape is validated once at the
-- artifact gate (ModelAsset.validate), so these tests cover the IR-level
-- assembly contract: key resolution, stale-schema rejection, the required
-- lists, name/semantic resolution, and the precomputed bindings.

local Assert = require("tests.support.Assert")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local AnimationClip = require("libs.assets.src.AnimationClip")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function jointClip()
  return AnimationClip.new({
    id = "c1",
    name = "open",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    -- A minimal compiled stub: validation requires the payload, and the
    -- samplers only touch it when the clip actually plays through them.
    compiled = {},
    tracks = {
      {
        target = 0,
        channels = {
          rotation = { interpolation = "linear", keys = { { frame = 0, value = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } } } },
        },
      },
    },
    semanticNames = { "door.open" },
  })
end

-- A material clip binding onto the fixture's "wall" material, listed in the
-- definition's animations like every playable clip.
local function materialClip()
  return AnimationClip.new({
    id = "c2",
    name = "fade",
    category = "material",
    kind = "color",
    frameCount = 4,
    compiled = {},
    tracks = {
      {
        target = "wall",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0x203C } } } },
      },
    },
  })
end

local function definitionSpec()
  return {
    key = "model:test",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
      {
        index = 1,
        name = "leaf",
        parentIndex = 0,
        translation = { x = 1, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      {
        id = "m0",
        name = "m0",
        nodeIndex = 1,
        materialIndex = 0,
        geometry = "fixtures/m0.g4mesh",
      },
    },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
    },
    animations = { jointClip() },
  }
end

function T.fixture_definition_is_valid()
  local def = NitroModelFixture.doorDefinition()
  Assert.equal(def.key, "fixture:nitro-door")
  Assert.equal(#def.nodes, 1)
  Assert.equal(#def.meshes, 1)
  Assert.equal(#def.animations, 2)
end

-- A spec that still carries the removed key is a stale-schema artifact and
-- fails loudly at the load boundary.
function T.new_rejects_a_source_backend_key()
  local s = definitionSpec()
  s.sourceBackend = "nitro"
  throwsCode("MODEL_DEF_BAD_SOURCE_BACKEND", function()
    return ModelDefinition.new(s)
  end)
end

-- The IR-level shape requirements: the required lists and the animation
-- name/semantic resolution rules. The descriptor field shapes themselves are
-- gate-owned (ModelAsset.validate), so they are not re-checked here.
function T.new_enforces_the_ir_level_requirements()
  local s = definitionSpec()
  s.sourceBackend = "vrm"
  throwsCode("MODEL_DEF_BAD_SOURCE_BACKEND", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.animations = nil
  throwsCode("MODEL_DEF_BAD_ANIMATIONS", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.nodes = {}
  throwsCode("MODEL_DEF_NO_NODES", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.meshes = {}
  throwsCode("MODEL_DEF_NO_MESHES", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.materials = {}
  throwsCode("MODEL_DEF_NO_MATERIALS", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.animations[1].name = "open"
  s.animations[2] = s.animations[1]
  throwsCode("MODEL_DEF_DUPLICATE_ANIMATION", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  local first = jointClip()
  first.name = "open"
  local second = jointClip()
  second.id = "c2"
  second.name = "open2"
  first.semanticNames = { "door.open" }
  second.semanticNames = { "door.open" }
  s.animations = { first, second }
  throwsCode("MODEL_DEF_DUPLICATE_SEMANTIC", function()
    return ModelDefinition.new(s)
  end)
  -- A clip name colliding with another clip's semantic role is ambiguous.
  s = definitionSpec()
  local role = jointClip()
  role.semanticNames = { "door.open" }
  local name = jointClip()
  name.id = "c2"
  name.name = "door.open"
  name.semanticNames = {}
  s.animations = { role, name }
  throwsCode("MODEL_DEF_NAME_SEMANTIC_COLLISION", function()
    return ModelDefinition.new(s)
  end)
end

function T.animations_resolve_by_name_and_semantic()
  local def = ModelDefinition.new(definitionSpec())
  Assert.equal(def:animation("open").id, "c1")
  Assert.equal(def:animation("door.open").id, "c1", "semantic roles resolve")
  Assert.isNil(def:animation("missing"))
end

-- Bindings are precomputed at assembly for every listed clip -- node clips
-- map node indices to themselves, material clips map material names and
-- carry the material-index -> track-index table the evaluator consumes.
function T.binding_is_precomputed_for_node_and_material_clips()
  local s = definitionSpec()
  s.animations = { jointClip(), materialClip() }
  local def = ModelDefinition.new(s)
  local joint = def:animation("open")
  local jointBinding = def:binding(joint)
  Assert.notNil(jointBinding)
  Assert.deepEqual(jointBinding.map, { [0] = 0 })

  local material = def:animation("fade")
  local materialBinding = def:binding(material)
  Assert.notNil(materialBinding)
  Assert.deepEqual(materialBinding.map, { wall = 0 })
  -- The MaterialEvaluator's per-material track lookup consumes the
  -- precomputed material-index -> track-index mapping.
  Assert.deepEqual(materialBinding.trackByMaterial, { [0] = 0 })
end

-- A clip outside the animations list has no binding: an unlisted clip fails
-- loudly at binding.
function T.binding_rejects_a_clip_outside_the_animations_list()
  local def = ModelDefinition.new(definitionSpec())
  local stray = materialClip()
  stray.id = "c9"
  stray.name = "stray"
  local ok, err = pcall(function()
    return def:binding(stray)
  end)
  Assert.isFalse(ok, "an unlisted clip has no binding")
  Assert.isTrue(tostring(err):find("not in the animations list", 1, true) ~= nil)
end

-- The complete serialized nitro descriptor shape MapAssetCompiler writes:
-- schema/kind, the stamped key, dynamic batches referencing .g4mesh geometry
-- with the full per-segment polygon draw state, materials, and compiled
-- clips. Built fresh per call so a test can corrupt one field in isolation.
local function nitroDescriptor()
  return {
    schema = "g4-model-v3",
    key = "outdoor:26:door",
    memberId = 26,
    kind = "nitro-dynamic",
    dynamic = {
      nodes = NitroModelFixture.doorProgram().nodes,
      transformProgram = NitroModelFixture.doorProgram(),
      batches = {
        {
          id = "draw0.seg0",
          drawIndex = 0,
          segmentIndex = 0,
          nodeIndex = 0,
          materialIndex = 0,
          transformMode = "static",
          positionSource = "draw",
          geometry = "assets/generated/maps/geometry/abc.g4mesh",
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 3,
          translucentDepthWrite = false,
          depthEqual = true,
          polygonAlpha = 31,
          lightMask = 5,
          fogEnabled = false,
        },
      },
    },
    materials = NitroModelFixture.doorDefinition().materials,
    animations = { NitroModelFixture.doorOpenClip() },
  }
end

function T.from_nitro_descriptor_assembles_the_runtime_definition()
  local desc = nitroDescriptor()
  local def = ModelDefinition.fromNitroDescriptor(desc, { key = desc.key })
  Assert.equal(def.key, "outdoor:26:door")
  Assert.equal(#def.meshes, 1)
  Assert.equal(def.meshes[1].geometry, "assets/generated/maps/geometry/abc.g4mesh")
  local draw = def.backend.meshes["draw0.seg0"]
  Assert.equal(draw.drawIndex, 0)
  Assert.equal(draw.positionSource, "draw")
  Assert.equal(draw.cullMode, "back")
  Assert.equal(draw.polygonId, 3)
  Assert.equal(draw.depthEqual, true)
  Assert.notNil(def:animation("door.open"))
  -- Descriptor assembly precomputes the clip bindings: the compiled door
  -- clip binds onto the assembled definition without any later rescan.
  Assert.notNil(def:binding(assert(def:animation("door.open"))))
end

-- The straddle provenance of a descriptor batch survives assembly onto the
-- backend mesh record, so the pose backend can resolve both sources and the
-- draw path can reproduce the DS per-vertex bend.
function T.from_nitro_descriptor_carries_the_straddle_provenance()
  local desc = nitroDescriptor()
  desc.dynamic.batches[1].straddle = { leading = 2, source = "draw" }
  local def = ModelDefinition.fromNitroDescriptor(desc, { key = desc.key })
  Assert.deepEqual(def.backend.meshes["draw0.seg0"].straddle, { leading = 2, source = "draw" })
end

-- A generated descriptor that omits the key must fail at the load boundary
-- with the descriptor's own diagnostic, never with a plausible default key.
function T.from_nitro_descriptor_requires_the_key()
  local desc = nitroDescriptor()
  desc.key = nil
  throwsCode("NITRO_DESC_NO_KEY", function()
    return ModelDefinition.fromNitroDescriptor(desc)
  end)
  -- The loader supplies the key through opts when it knows the model key;
  -- that path still assembles.
  local def = ModelDefinition.fromNitroDescriptor(desc, { key = "outdoor:26:door" })
  Assert.equal(def.key, "outdoor:26:door")
end

return { tests = T }
