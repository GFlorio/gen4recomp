-- The entrance-effect runtime composition loads every required field-effect
-- definition from the current generated bundle, including the persistent
-- player surf attachment.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEntranceIndicatorRuntime = require("game.hgss.src.field.FieldEntranceIndicatorRuntime")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = { tests = {} }

local KINDS = { "warp_entrance", "tall_grass", "very_tall_grass", "trainer_reveal", "surf_attachment" }

local function staticModel(key)
  return {
    schema = ModelAsset.SCHEMA,
    key = key,
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
      },
    },
  }
end

local function cacheWithIndexSchema(schema)
  local index = { schema = schema, effects = {} }
  for _, kind in ipairs(KINDS) do
    index.effects[kind] = { definition = kind, path = FieldEffectAssetCache.definitionPath(kind) }
  end
  return {
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return index
      end
      local kind = path:match("/([^/]+)%.lua$")
      if kind == "surf_attachment" then
        return {
          model = staticModel("field-effect:surf-attachment"),
          presentation = {
            initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
            oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
            playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
            attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
            yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
          },
        }
      end
      if kind == "warp_entrance" then
        return { model = staticModel("field-effect:warp-entrance"), lifetime = 1 }
      end
      return { model = staticModel("field-effect:" .. kind) }
    end,
  }
end

T.tests["loads all five current definitions including the surf attachment"] = function()
  local bundle = FieldEntranceIndicatorRuntime.load(cacheWithIndexSchema(Contract.fieldEffects.indexSchema))
  Assert.equal(bundle.schema, Contract.fieldEffects.indexSchema)
  for _, kind in ipairs(KINDS) do
    Assert.notNil(bundle.effects[kind], "runtime must load " .. kind)
  end
  local surf = assert(bundle.effects.surf_attachment)
  ModelAsset.validate(surf.model)
  Assert.equal(surf.model.kind, "static")
  Assert.equal(surf.presentation.oscillator.stepY, (1 / 4) / 16)
  Assert.equal(surf.presentation.yawDegrees.north, 180)
  Assert.equal(surf.presentation.yawDegrees.south, 0)
  Assert.equal(surf.presentation.yawDegrees.west, 270)
  Assert.equal(surf.presentation.yawDegrees.east, 90)
  Assert.notNil(bundle.model)
end

T.tests["rejects a stale field-effect index schema"] = function()
  local ok = pcall(FieldEntranceIndicatorRuntime.load, cacheWithIndexSchema("g4-field-effect-index-v1"))
  Assert.isFalse(ok, "a stale index schema must not load")
end

return T
