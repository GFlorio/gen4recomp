-- Field-effect readiness is defined by the strict v3 index and every
-- source-derived definition it references.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.ModelAsset")

local T = { tests = {} }

local function validModel()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-effect:warp-entrance",
    kind = "static",
    batches = {
      {
        geometry = "mesh-a",
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 5,
        fogEnabled = false,
      },
    },
    materials = {
      {
        id = 0,
        name = "effect",
        texture = "texture-a",
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
        variants = {
          {
            name = "pattern.1",
            texture = "texture-variant",
            width = 1,
            height = 1,
            textureFormat = 3,
            alphaUsage = { hasZero = false, hasPartial = false, hasOpaque = true },
          },
        },
      },
    },
  }
end

local function validDynamicModel(animationMemberId)
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-effect:tall-grass",
    kind = "nitro-dynamic",
    dynamic = {
      nodes = { { name = "root" } },
      transformProgram = {},
      batches = {
        {
          id = "draw0",
          drawIndex = 0,
          nodeIndex = 0,
          materialIndex = 0,
          geometry = "grass.mesh",
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
          lightMask = 5,
          fogEnabled = false,
        },
      },
    },
    materials = {
      {
        id = 0,
        name = "grass",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        polygonMode = "modulation",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
        colors = {
          diffuse = { r = 255, g = 255, b = 255 },
          ambient = { r = 255, g = 255, b = 255 },
          specular = { r = 255, g = 255, b = 255 },
          emission = { r = 0, g = 0, b = 0 },
        },
      },
    },
    animations = {
      {
        id = "grass-animation",
        name = "grass",
        category = "joint",
        kind = "trs",
        frameCount = 1,
        tracks = { { target = 0, targetIndex = 0 } },
        semanticNames = {},
        source = {
          type = "nitro",
          format = "NSBCA",
          archive = "build_anim",
          memberId = animationMemberId,
          sha1 = "anim-sha",
        },
        compiled = {
          anmFlags = 0,
          rotData = { { control = 0, a = 0, b = 0 } },
          pivotData = { { 0, 0, 0, 0, 0 } },
          targets = {
            {
              nodeIndex = 0,
              channels = {
                trans = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
                rot = { source = "curve", rate = 1, limit = 1, storage = "fx16", keys = { 0 } },
                scale = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
              },
            },
          },
        },
      },
    },
  }
end

local function cache(model, present, wrongProvenance, sourceOverride)
  local index = {
    schema = "g4-field-effect-index-v1",
    effects = {},
  }
  for _, kind in ipairs({ "warp_entrance", "tall_grass", "very_tall_grass" }) do
    index.effects[kind] = {
      kind = kind == "warp_entrance" and "model" or "animated_model",
      definition = kind,
      path = FieldEffectAssetCache.definitionPath(kind),
    }
  end
  return {
    read = function(_, path)
      return path == FieldEffectAssetCache.markerPath() and "expected" or nil
    end,
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return index
      end
      local kind = path:match("/([^/]+)%.lua$")
      if kind == "warp_entrance" then
        return { model = model, lifetime = 1, kind = "model" }
      end
      local defaultMembers = kind == "tall_grass" and { 140 } or { 146 }
      local source = sourceOverride and sourceOverride[kind]
      local members = source and source.animationMembers or defaultMembers
      return {
        model = validDynamicModel(kind == "tall_grass" and 140 or 146),
        kind = "animated_model",
        source = {
          renderer = wrongProvenance and 99 or (kind == "tall_grass" and 8 or 12),
          modelMembers = source and source.modelMembers or (kind == "tall_grass" and { 126 } or { 122 }),
          animationArchive = "build_anim",
          animationMembers = members,
        },
        animationSourceSha1 = "anim-sha",
      }
    end,
    exists = function(_, path)
      return present[path] == true
    end,
  }
end

T.tests["accepts a complete canonical model and every referenced asset"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }),
    "expected"
  )
  Assert.isTrue(ready)
end

T.tests["rejects a missing referenced asset"] = function()
  local ready =
    FieldEffectAssetCache.isReady(cache(validModel(), { ["mesh-a"] = true, ["grass.mesh"] = true }), "expected")
  Assert.isFalse(ready)
end

T.tests["rejects wrong renderer provenance"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }, true),
    "expected"
  )
  Assert.isFalse(ready)
end

T.tests["rejects incomplete grass source members"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(
      validModel(),
      {
        ["mesh-a"] = true,
        ["texture-a"] = true,
        ["texture-variant"] = true,
      },
      false,
      {
        tall_grass = { modelMembers = { 126 }, animationMembers = { 140 } },
        very_tall_grass = { modelMembers = { 122 }, animationMembers = { 146 } },
      }
    ),
    "expected"
  )
  Assert.isFalse(ready, "incomplete grass source metadata must be rejected")
end

return T
