-- ModelAsset: strict descriptor validation and reference traversal. An
-- untextured variant is a first-class output of the compiler -- a pattern key
-- the model's embedded TEX0 does not define still selects a variant, which
-- then draws untextured exactly as the DS does -- so validation must accept
-- it while still rejecting malformed records, and reference traversal must
-- not hand nil paths downstream.
--
-- ModelAsset.validate is the authoritative artifact gate: every model
-- descriptor MapAssetCompiler emits is validated here before MapCacheWriter
-- publishes it and MapAssetCache reads it back, so the emitted shape (the
-- fixtures below) must validate and any malformed variant of it must raise
-- ModelAsset.ERROR_INVALID. The gate covers the full serialized contract: batch
-- draw state, the per-kind material contract (scene-form materials for
-- static descriptors, the DS-register shape for dynamic ones), and the
-- per-kind compiled clip payload (category/kind vocabulary plus the payload
-- shapes the samplers consume), so the runtime constructors may assume a
-- validated record is valid.

local Assert = require("tests.support.Assert")
local ModelAsset = require("libs.assets.src.ModelAsset")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isTrue(not ok, "expected raise, got success")
  Assert.equal(code, err.code, "error code")
end

-- The full dynamic material shape the animated compiler emits: the DS
-- register block, the base color/alpha carrier, the render classification
-- fields, the sampler state, and optional bound-texture metadata.
local function dynamicMaterial()
  return {
    id = 0,
    name = "mg08_r10",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function dynamicDescriptor(material)
  return {
    schema = ModelAsset.SCHEMA,
    key = "indoor:1:abc",
    memberId = 1,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { material or dynamicMaterial() },
    animations = {},
  }
end

function T.validate_accepts_untextured_variant()
  local material = dynamicMaterial()
  material.texture = "assets/generated/maps/textures/base.png"
  material.textureFormat = 3
  material.alphaUsage = { hasZero = true }
  material.variants = {
    {
      name = "mg08_r10.1",
      texture = "assets/generated/maps/textures/v1.png",
      width = 64,
      height = 64,
      textureFormat = 3,
      alphaUsage = { hasZero = true },
    },
    { name = "mg08_r10.2" },
    {
      name = "mg08_r10.3",
      texture = "assets/generated/maps/textures/v3.png",
      width = 32,
      height = 32,
      textureFormat = 7,
    },
  }
  local desc = dynamicDescriptor(material)
  Assert.equal(ModelAsset.validate(desc), desc)
end

function T.validate_rejects_non_string_variant_texture()
  local material = dynamicMaterial()
  material.variants = { { name = "a.1", texture = 7 } }
  local desc = dynamicDescriptor(material)
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.referenced_paths_cover_only_textured_variants()
  local material = dynamicMaterial()
  material.texture = "assets/generated/maps/textures/base.png"
  material.textureFormat = 3
  material.alphaUsage = { hasZero = true }
  material.variants = {
    {
      name = "mg08_r10.1",
      texture = "assets/generated/maps/textures/v1.png",
      width = 64,
      height = 64,
      textureFormat = 3,
    },
    { name = "mg08_r10.2" },
  }
  local desc = dynamicDescriptor(material)
  local paths = ModelAsset.referencedPaths(desc)
  Assert.isTrue(not paths[3], "untextured variant must not append a nil path")
  local found = 0
  for _, path in ipairs(paths) do
    Assert.equal("string", type(path))
    if path == "assets/generated/maps/textures/v1.png" then
      found = found + 1
    end
  end
  Assert.equal(1, found, "textured variant path is listed exactly once")
end

-- ---- authoritative artifact validation ----
--
-- The fixtures are the exact shapes MapAssetCompiler emits today (schema
-- ModelAsset.SCHEMA): dynamic batches carry the full polygon draw-state field
-- set (cullMode, polygonMode, polygonId, translucentDepthWrite, depthEqual,
-- polygonAlpha, lightMask, fogEnabled) plus id/nodeIndex/materialIndex/
-- drawIndex, dynamic
-- materials carry the four-channel colors block and the render fields, and
-- animation records carry the clip envelope plus a compiled payload whose
-- shape follows the clip kind. The valid shape must pass; each malformed
-- variant below must raise ModelAsset.ERROR_INVALID -- ModelAsset.validate is the
-- pre-publish gate MapCacheWriter runs every compiled descriptor through.

local function emittedNode()
  return {
    index = 0,
    name = "root",
    matrixStackIndex = 0,
    translation = { x = 0, y = 0, z = 0 },
    rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    scale = { x = 1, y = 1, z = 1 },
    transZero = true,
    rotZero = true,
    scaleOne = true,
  }
end

local function emittedDynamicBatch()
  return {
    id = "draw0.seg0",
    drawIndex = 0,
    segmentIndex = 0,
    nodeIndex = 0,
    materialIndex = 0,
    transformMode = "static",
    positionSource = "draw",
    geometry = "assets/generated/maps/geometry/aaaaaaaa",
    cullMode = "back",
    polygonMode = "modulation",
    polygonId = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    polygonAlpha = 31,
    lightMask = 5,
    fogEnabled = false,
  }
end

local function emittedStaticBatch()
  return {
    geometry = "assets/generated/maps/geometry/aaaaaaaa",
    material = 0,
    node = 0,
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 31,
    polygonMode = "modulation",
    lightMask = 5,
    polygonId = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    fogEnabled = true,
    -- The static-only extra fields stay outside the shared draw-state schema.
    farClipEnabled = true,
    oneDotEnabled = false,
  }
end

-- The scene-form material record the static path emits: id/name plus the
-- sampler state (wrap/flip), the diffuse carrier, and the bound texture
-- metadata (present together, absent together).
local function emittedStaticMaterial()
  return {
    id = 0,
    name = "wall",
    texture = "assets/generated/maps/textures/base.png",
    textureFormat = 3,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function emittedDynamicMaterial()
  return {
    id = 0,
    name = "wall",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    alphaMode = "opaque",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
  }
end

-- A compiled NSBCA payload whose rotation curve spans all eight frames and
-- references pivot entry 0 (inside the compiled table).
local function emittedTrsClip()
  return {
    id = "build_anim-1",
    name = "door_op",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { "door.open" },
    source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
    compiled = {
      anmFlags = 0,
      rotData = { { control = 0x0024, a = 4096, b = 0 } },
      pivotData = { { 4096, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = {
              x = { source = "model" },
              y = { source = "model" },
              z = { source = "model" },
            },
            rot = {
              source = "curve",
              rate = 1,
              limit = 8,
              storage = "fx16",
              keys = { 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000 },
            },
            scale = {
              x = { source = "model" },
              y = { source = "model" },
              z = { source = "model" },
            },
          },
        },
      },
    },
  }
end

-- A compiled NSBTA payload: all five channels as explicit constants.
local function emittedTexsrtClip()
  return {
    id = "build_anim-2",
    name = "en_sp1",
    category = "material",
    kind = "texsrt",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBTA", archive = "build_anim", memberId = 2 },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            transS = { source = "constant", value = 0 },
            transT = { source = "constant", value = 0 },
            rot = { source = "constant", value = 0x10000000 },
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
          },
        },
      },
    },
  }
end

-- A compiled NSBMA payload: all five material registers as explicit
-- constants (the compiler emits every channel).
local function emittedColorClip()
  return {
    id = "build_anim-4",
    name = "psentry_rode",
    category = "material",
    kind = "color",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBMA", archive = "build_anim", memberId = 4 },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            diffuse = { source = "constant", value = 0x7FFF },
            ambient = { source = "constant", value = 0x4210 },
            specular = { source = "constant", value = 0 },
            emission = { source = "constant", value = 0x001F },
            alpha = { source = "constant", value = 31 },
          },
        },
      },
    },
  }
end

local function emittedDynamicDescriptor()
  return {
    schema = ModelAsset.SCHEMA,
    key = "outdoor:26:door",
    memberId = 26,
    kind = "nitro-dynamic",
    dynamic = {
      nodes = { emittedNode() },
      transformProgram = {
        name = "wk_door3",
        scalingRule = 0,
        posScale = 1,
        invPosScale = 1,
        tileScale = 1 / 16,
        nodes = { emittedNode() },
        commands = {},
      },
      batches = { emittedDynamicBatch() },
    },
    materials = { emittedDynamicMaterial() },
    animations = { emittedTrsClip() },
  }
end

local function emittedStaticDescriptor()
  return {
    schema = ModelAsset.SCHEMA,
    key = "outdoor:12:map",
    memberId = 12,
    kind = "static",
    batches = { emittedStaticBatch() },
    materials = { emittedStaticMaterial() },
  }
end

function T.validate_accepts_the_current_emitted_dynamic_shape()
  local desc = emittedDynamicDescriptor()
  Assert.equal(ModelAsset.validate(desc), desc)
end

function T.validate_accepts_the_current_emitted_static_shape()
  local desc = emittedStaticDescriptor()
  Assert.equal(ModelAsset.validate(desc), desc)
end

function T.validate_rejects_a_batch_missing_light_mask()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].lightMask = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_out_of_range_polygon_id()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].polygonId = 64
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_duplicate_batch_ids()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[2] = {}
  for k, v in pairs(desc.dynamic.batches[1]) do
    desc.dynamic.batches[2][k] = v
  end
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_animation_without_tracks()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].tracks = {}
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- A batch without a geometry path (an embedded-batch record, or any other
-- geometry-less shape) is not loadable: the runtime builds meshes from the
-- .g4mesh path only.
function T.validate_rejects_a_dynamic_batch_without_geometry()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].geometry = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_descriptor_without_materials()
  local desc = emittedDynamicDescriptor()
  desc.materials = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_out_of_range_material_color_channel()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].colors.diffuse = { r = 256, g = 0, b = 0 }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_unknown_material_color_channel()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].colors.rim = { r = 255, g = 255, b = 255 }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_batch_with_an_out_of_range_node_index()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].nodeIndex = 1
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_batch_with_an_out_of_range_material_index()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].materialIndex = 1
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- ---- the strict material contract ----

-- The static path emits the scene-form material record; a record missing a
-- required field is malformed generated data, never a default.
function T.validate_rejects_a_static_material_missing_wrap()
  local desc = emittedStaticDescriptor()
  desc.materials[1].wrap = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_static_material_missing_an_id()
  local desc = emittedStaticDescriptor()
  desc.materials[1].id = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- The static material's texture metadata is coupled: a texture without its
-- format (or a format without a texture) is a shape the compiler never emits.
function T.validate_rejects_a_static_texture_without_a_format()
  local desc = emittedStaticDescriptor()
  desc.materials[1].textureFormat = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- The dynamic material contract: the DS register block (colors), the alpha
-- carrier (baseColor), and the render fields are required, so the runtime
-- never defaults them.
function T.validate_rejects_a_dynamic_material_missing_base_color()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].baseColor = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- Material ids are the list positions: the runtime indexes material state
-- by position, so a descriptor whose ids are not contiguous is malformed
-- generated data (the compiler assigns each material its index).
function T.validate_rejects_non_contiguous_material_ids()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].id = 5
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_static_material_with_a_non_contiguous_id()
  local desc = emittedStaticDescriptor()
  desc.materials[1].id = 3
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_material_missing_polygon_alpha()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].polygonAlpha = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_material_with_an_unknown_alpha_mode()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].alphaMode = "pbr"
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_material_missing_tex_dimensions()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].texWidth = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_material_without_the_colors_block()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].colors = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- ---- the strict animation contract ----

function T.validate_rejects_an_unknown_animation_category()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].category = "visibility"
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_unknown_clip_kind()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].kind = "lipsync"
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_clip_without_a_compiled_payload()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].compiled = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_descriptor_without_animations()
  local desc = emittedDynamicDescriptor()
  desc.animations = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- The compiled payload shape follows the clip kind: a trs clip whose curve
-- limit disagrees with its frame count is a payload the sampler cannot
-- safely consume (the compiler asserts limit == numFrame).
function T.validate_rejects_a_trs_curve_whose_limit_mismatches_the_frame_count()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].compiled.targets[1].channels.rot.limit = 6
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- Rotation keys are compiled against the tables the clip references; a key
-- beyond the compiled table is a payload the sampler would read past.
function T.validate_rejects_a_trs_rotation_key_beyond_the_compiled_table()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].compiled.targets[1].channels.rot.keys[8] = 0x8001
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_trs_pivot_index_above_eight()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].compiled.rotData[1].control = 0x10 + 9
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_trs_rotation_curve_shorter_than_its_frames()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].compiled.targets[1].channels.rot.keys = { 0x8000 }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_texsrt_clip_with_a_missing_channel()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = emittedTexsrtClip()
  desc.animations[1].compiled.targets[1].channels.rot = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_texsrt_clip_with_a_bad_channel_source()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = emittedTexsrtClip()
  desc.animations[1].compiled.targets[1].channels.rot = { source = "absent" }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_color_clip_with_a_missing_channel()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = emittedColorClip()
  desc.animations[1].compiled.targets[1].channels.alpha = nil
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- NSBTA/NSBMA channels have no model source: the material-animation source
-- vocabulary is {constant, curve}, so a payload carrying a model source is
-- malformed data the samplers cannot consume.
function T.validate_rejects_a_texsrt_clip_with_a_model_source()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = emittedTexsrtClip()
  desc.animations[1].compiled.targets[1].channels.rot = { source = "model" }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- The texsrt payload contract is the shared validator's: a curve that does
-- not cover every reachable frame is a payload the sampler reads past.
function T.validate_rejects_a_texsrt_curve_with_insufficient_keys()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = emittedTexsrtClip()
  desc.animations[1].compiled.targets[1].channels.transS =
    { source = "curve", rate = 1, limit = 4, storage = "fx16", keys = { 0, 1, 2 } }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- Track target names are the runtime binding keys: two tracks resolving to
-- the same name are ambiguous even when their target indices differ.
function T.validate_rejects_texsrt_duplicate_track_target_names()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = emittedTexsrtClip()
  desc.animations[1].compiled.targets[2] = {
    index = 1,
    name = "wall",
    channels = {
      transS = { source = "constant", value = 0 },
      transT = { source = "constant", value = 0 },
      rot = { source = "constant", value = 0x10000000 },
      scaleS = { source = "constant", value = 0x1000 },
      scaleT = { source = "constant", value = 0x1000 },
    },
  }
  desc.animations[1].tracks = {
    { target = "wall", targetIndex = 0 },
    { target = "wall", targetIndex = 1 },
  }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_color_clip_with_a_model_source()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = emittedColorClip()
  desc.animations[1].compiled.targets[1].channels.diffuse = { source = "model" }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- Pattern keys index the compiled texture/palette name tables; an index
-- beyond them is malformed generated data (the evaluator would fail the
-- variant lookup at draw time).
function T.validate_rejects_a_pattern_key_index_out_of_range()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = {
    id = "build_anim-3",
    name = "pattern",
    category = "material",
    kind = "pattern",
    frameCount = 8,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBTP", archive = "build_anim", memberId = 3 },
    compiled = {
      textureNames = { "v1" },
      paletteNames = { "v1_pl" },
      targets = {
        {
          index = 0,
          name = "wall",
          rate = 0x1000,
          keys = { { frame = 0, texIdx = 1, plttIdx = 0xFF } },
        },
      },
    },
  }
  throwsCode(ModelAsset.ERROR_INVALID, function()
    ModelAsset.validate(desc)
  end)
end

-- The compiled NSBTP payload trusts its arrays: keyCount/numTextures/
-- numPalettes counts are not part of the serialized shape, so a count-less
-- payload is current-schema data the gate accepts.
function T.validate_accepts_a_pattern_payload_without_counts()
  local desc = emittedDynamicDescriptor()
  desc.animations[1] = {
    id = "build_anim-3",
    name = "pattern",
    category = "material",
    kind = "pattern",
    frameCount = 8,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBTP", archive = "build_anim", memberId = 3 },
    compiled = {
      textureNames = { "v1" },
      paletteNames = { "v1_pl" },
      targets = {
        {
          index = 0,
          name = "wall",
          rate = 0x1000,
          keys = { { frame = 0, texIdx = 0, plttIdx = 0xFF } },
        },
      },
    },
  }
  Assert.equal(ModelAsset.validate(desc), desc)
end

return { tests = T }
