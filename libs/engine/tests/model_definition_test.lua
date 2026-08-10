-- ModelDefinition: the engine-native model IR -- validation, semantic
-- animation resolution, and the loading-time binding maps a glTF-style
-- import would produce.

local Assert = require("tests.support.Assert")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local AnimationClip = require("libs.engine.src.AnimationClip")
local GenericModelFixture = require("tests.support.GenericModelFixture")

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
    tracks = {
      {
        target = 1,
        channels = {
          rotation = { interpolation = "linear", keys = { { frame = 0, value = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } } } },
        },
      },
    },
    semanticNames = { "door.open" },
  })
end

local function definitionSpec()
  return {
    key = "model:test",
    sourceBackend = "generic",
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
        batch = { vertices = { { x = 0, y = 0, z = 0 } }, indices = { 0, 0, 0 } },
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
  local def = GenericModelFixture.doorDefinition()
  Assert.equal(def.key, "fixture:door")
  Assert.equal(def.sourceBackend, "generic")
  Assert.equal(#def.nodes, 4)
  Assert.equal(#def.meshes, 3)
  Assert.equal(#def.animations, 3)
  Assert.equal(def.instanceMetadata.fixture, "generic-door")
end

function T.validation_rejects_bad_shapes()
  local s = definitionSpec()
  s.sourceBackend = "vrm"
  throwsCode("MODEL_DEF_BAD_SOURCE_BACKEND", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.materials[1].alphaMode = "pbr"
  throwsCode("MODEL_DEF_BAD_ALPHA_MODE", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.nodes[2].index = 2
  throwsCode("MODEL_DEF_NODE_INDEX_MISMATCH", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.nodes[2].parentIndex = 5
  throwsCode("MODEL_DEF_BAD_PARENT", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.meshes[1].nodeIndex = 7
  throwsCode("MODEL_DEF_MESH_BAD_NODE", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.meshes[1].materialIndex = 7
  throwsCode("MODEL_DEF_MESH_BAD_MATERIAL", function()
    return ModelDefinition.new(s)
  end)
  s = definitionSpec()
  s.materials[1].baseColor = { r = 300, g = 0, b = 0, a = 255 }
  throwsCode("MODEL_DEF_BAD_BASE_COLOR", function()
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
end

function T.animations_resolve_by_name_and_semantic()
  local def = ModelDefinition.new(definitionSpec())
  Assert.equal(def:animation("open").id, "c1")
  Assert.equal(def:animation("door.open").id, "c1", "semantic roles resolve")
  Assert.isNil(def:animation("missing"))
  Assert.equal(#def:animationNames(), 1)
end

function T.binding_map_maps_node_and_material_targets()
  local def = ModelDefinition.new(definitionSpec())
  local joint = def:animation("open")
  Assert.deepEqual(def:bindingMap(joint), { [1] = 1 })

  local material = AnimationClip.new({
    id = "c2",
    name = "fade",
    category = "material",
    kind = "color",
    frameCount = 4,
    tracks = {
      {
        target = "wall",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0x203C } } } },
      },
    },
  })
  Assert.deepEqual(def:bindingMap(material), { wall = 0 })

  local unmapped = AnimationClip.new({
    id = "c3",
    name = "ghost",
    category = "material",
    kind = "color",
    frameCount = 4,
    tracks = {
      {
        target = "absent",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0 } } } },
      },
    },
  })
  Assert.deepEqual(def:bindingMap(unmapped), {}, "unmatched names stay unmapped")
end

function T.gltf_shaped_ir_representations()
  -- The future glTF mapping checks: the IR must represent node TRS, a named
  -- clip, skin joints + inverse bind matrices, four vertex influences, a
  -- base-color material, and an alpha mode -- the fixture is the proof.
  local def = GenericModelFixture.doorDefinition()
  Assert.equal(def.nodes[2].name, "leaf")
  Assert.equal(def.nodes[2].parentIndex, 0)
  Assert.equal(def.meshes[3].id, "skin")
  local skin = def.skins[1]
  Assert.equal(skin.id, "skin")
  Assert.deepEqual(skin.joints, { 2, 3 })
  Assert.equal(#skin.inverseBindMatrices[2], 16)
  local batch = def.meshes[3].batch
  Assert.equal(#batch.vertices[1].joints, 4)
  Assert.equal(#batch.vertices[1].weights, 4)
  Assert.equal(batch.vertices[1].weights[1] + batch.vertices[1].weights[2], 255)
  Assert.equal(def.materials[1].baseColor.r, 255)
  Assert.equal(def.materials[2].alphaMode, "mask")
  Assert.equal(def:animation("DoorOpen").source.type, "gltf")
end

return T
