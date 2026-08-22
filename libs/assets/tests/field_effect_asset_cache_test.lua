-- Field-effect readiness is defined by the canonical model descriptor and its
-- referenced assets, without a second source-coupled manifest.

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

local function cache(model, present)
  return {
    read = function(_, path)
      return path == FieldEffectAssetCache.markerPath() and "expected" or nil
    end,
    loadLua = function(_, path)
      Assert.equal(path, FieldEffectAssetCache.modelPath(), "readiness must not load a manifest")
      return model
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

return T
