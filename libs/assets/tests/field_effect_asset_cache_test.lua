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
      local defaultMembers = kind == "tall_grass" and { 140, 141, 142, 143 } or { 146 }
      local source = sourceOverride and sourceOverride[kind]
      local members = source and source.animationMembers or defaultMembers
      local frames = {}
      for _, memberId in ipairs(members) do
        frames[#frames + 1] = {
          memberId = memberId,
          duration = 1,
          format = "NANR",
          name = "frame",
          values = { { numFrame = 1 } },
        }
      end
      return {
        model = model,
        lifetime = #members,
        kind = "animated_model",
        source = {
          renderer = wrongProvenance and 99 or (kind == "tall_grass" and 8 or 12),
          modelMembers = source and source.modelMembers or (kind == "tall_grass" and { 126, 127 } or { 122 }),
          animationArchive = "build_anim",
          animationMembers = members,
        },
        animation = {
          schema = "g4-field-effect-animation-v1",
          sourceMembers = members,
          frames = frames,
        },
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
    }),
    "expected"
  )
  Assert.isTrue(ready)
end

T.tests["rejects a missing referenced asset"] = function()
  local ready = FieldEffectAssetCache.isReady(cache(validModel(), { ["mesh-a"] = true }), "expected")
  Assert.isFalse(ready)
end

T.tests["rejects wrong renderer provenance"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
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
