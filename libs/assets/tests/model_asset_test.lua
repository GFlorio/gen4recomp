-- ModelAsset: strict descriptor validation and reference traversal. An
-- untextured variant is a first-class output of the compiler -- a pattern key
-- the model's embedded TEX0 does not define still selects a variant, which
-- then draws untextured exactly as the DS does -- so validation must accept
-- it while still rejecting malformed records, and reference traversal must
-- not hand nil paths downstream.
--
-- ModelAsset.validate is the authoritative artifact validator: every model
-- descriptor MapAssetCompiler emits is validated here before MapCacheWriter
-- publishes it, so the emitted shape (the fixtures below) must validate and
-- any malformed variant of it must raise MODEL_DESC_INVALID.

local Assert = require("tests.support.Assert")
local ModelAsset = require("libs.assets.src.ModelAsset")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isTrue(not ok, "expected raise, got success")
  Assert.equal(code, err.code, "error code")
end

local function dynamicDescriptor(materials)
  return {
    schema = ModelAsset.SCHEMA,
    key = "indoor:1:abc",
    memberId = 1,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = materials,
    animations = {},
  }
end

function T.validate_accepts_untextured_variant()
  local desc = dynamicDescriptor({
    {
      id = 0,
      name = "mg08_r10",
      texture = "assets/generated/maps/textures/base.png",
      variants = {
        { name = "mg08_r10.1", texture = "assets/generated/maps/textures/v1.png" },
        { name = "mg08_r10.2" },
        { name = "mg08_r10.3", texture = "assets/generated/maps/textures/v3.png" },
      },
    },
  })
  Assert.equal(ModelAsset.validate(desc), desc)
end

function T.validate_rejects_non_string_variant_texture()
  local desc = dynamicDescriptor({
    { id = 0, name = "m", variants = { { name = "a.1", texture = 7 } } },
  })
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.referenced_paths_cover_only_textured_variants()
  local desc = dynamicDescriptor({
    {
      id = 0,
      name = "mg08_r10",
      texture = "assets/generated/maps/textures/base.png",
      variants = {
        { name = "mg08_r10.1", texture = "assets/generated/maps/textures/v1.png" },
        { name = "mg08_r10.2" },
      },
    },
  })
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
-- g4-model-v2): dynamic batches carry the full polygon draw-state field set
-- (cullMode, polygonMode, polygonId, translucentDepthWrite, depthEqual,
-- polygonAlpha, lightMask) plus id/nodeIndex/materialIndex/drawIndex, dynamic
-- materials carry the optional four-channel colors block, and animation
-- records carry the clip envelope. The valid shape must pass; each malformed
-- variant below must raise MODEL_DESC_INVALID -- ModelAsset.validate is the
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
    -- The static-only extra fields stay outside the shared draw-state schema.
    farClipEnabled = true,
    oneDotEnabled = false,
    fogEnabled = true,
  }
end

local function emittedMaterial()
  return {
    id = 0,
    name = "wall",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    alphaMode = "opaque",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
  }
end

local function emittedClip()
  return {
    id = "build_anim-1",
    name = "door_op",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { "door.open" },
    source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
    compiled = { anmFlags = 0, rotData = {}, pivotData = {}, targets = {} },
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
    materials = { emittedMaterial() },
    animations = { emittedClip() },
  }
end

local function emittedStaticDescriptor()
  local material = emittedMaterial()
  -- The static path emits no colors block (white diffuse only); the block
  -- is the dynamic path's per-register shape.
  material.colors = nil
  return {
    schema = ModelAsset.SCHEMA,
    key = "outdoor:12:map",
    memberId = 12,
    kind = "static",
    batches = { emittedStaticBatch() },
    materials = { material },
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
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_out_of_range_polygon_id()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].polygonId = 64
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_duplicate_batch_ids()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[2] = {}
  for k, v in pairs(desc.dynamic.batches[1]) do
    desc.dynamic.batches[2][k] = v
  end
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_animation_without_tracks()
  local desc = emittedDynamicDescriptor()
  desc.animations[1].tracks = {}
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_out_of_range_material_color_channel()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].colors.diffuse = { r = 256, g = 0, b = 0 }
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_an_unknown_material_color_channel()
  local desc = emittedDynamicDescriptor()
  desc.materials[1].colors.rim = { r = 255, g = 255, b = 255 }
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_batch_with_an_out_of_range_node_index()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].nodeIndex = 1
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

function T.validate_rejects_a_dynamic_batch_with_an_out_of_range_material_index()
  local desc = emittedDynamicDescriptor()
  desc.dynamic.batches[1].materialIndex = 1
  throwsCode("MODEL_DESC_INVALID", function()
    ModelAsset.validate(desc)
  end)
end

return T
