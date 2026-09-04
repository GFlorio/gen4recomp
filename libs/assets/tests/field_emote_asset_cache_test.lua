-- Field-emote cache validation: the generated descriptor keeps source-derived
-- actor attachment separate from the nested generic model asset.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local Errors = require("libs.errors.src.Errors")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = { tests = {} }

local FORMAT = "field-emotes-cache-v2"
local SCHEMA = "g4-field-emote-v1"
local MARKER = FORMAT .. ":rom:dep"

local function model()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-emote:exclamation",
    kind = "static",
    batches = {
      {
        geometry = FieldEmoteAssetCache.geometryPath("mesh-key"),
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
        name = "exclamation",
        texture = FieldEmoteAssetCache.texturePath("texture-key"),
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
end

local function descriptor()
  return {
    schema = SCHEMA,
    anchorOffset = { x = 0, y = 2, z = 0.0625 },
    model = model(),
  }
end

local function cacheWith(value)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldEmoteAssetCache.exclamationDescriptorPath(), value)
  cache:write(FieldEmoteAssetCache.geometryPath("mesh-key"), "mesh")
  cache:write(FieldEmoteAssetCache.texturePath("texture-key"), "texture")
  cache:write(FieldEmoteAssetCache.markerPath(), MARKER)
  return cache
end

function T.tests.current_descriptor_is_ready_and_preserves_the_source_anchor()
  local cache = cacheWith(descriptor())
  Assert.equal(FieldEmoteAssetCache.FORMAT, FORMAT)
  Assert.isTrue(FieldEmoteAssetCache.validateDescriptor(descriptor()))
  Assert.isTrue(FieldEmoteAssetCache.isReady(cache, MARKER), "the current field-emote descriptor must be ready")

  local loaded = assert(cache:loadLua(FieldEmoteAssetCache.exclamationDescriptorPath()))
  Assert.equal(loaded.schema, SCHEMA)
  Assert.deepEqual(loaded.anchorOffset, { x = 0, y = 2, z = 0.0625 })
  Assert.equal(loaded.model.key, "field-emote:exclamation")
end

function T.tests.bare_models_and_malformed_descriptors_are_not_ready()
  ---@type { name: string, value: any }[]
  local cases = {
    { name = "bare model", value = model() },
    { name = "extra key", value = descriptor() },
    { name = "missing x", value = descriptor() },
    { name = "missing y", value = descriptor() },
    { name = "missing z", value = descriptor() },
    { name = "wrong schema", value = descriptor() },
    { name = "string x", value = descriptor() },
    { name = "boolean y", value = descriptor() },
    { name = "nan z", value = descriptor() },
    { name = "positive infinity x", value = descriptor() },
    { name = "negative infinity y", value = descriptor() },
    { name = "invalid nested model", value = descriptor() },
    { name = "extra anchor key", value = descriptor() },
  }

  cases[2].value.extra = true
  cases[3].value.anchorOffset.x = nil
  cases[4].value.anchorOffset.y = nil
  cases[5].value.anchorOffset.z = nil
  cases[6].value.schema = "g4-other-v1"
  cases[7].value.anchorOffset.x = "0"
  cases[8].value.anchorOffset.y = false
  cases[9].value.anchorOffset.z = 0 / 0
  cases[10].value.anchorOffset.x = math.huge
  cases[11].value.anchorOffset.y = -math.huge
  cases[12].value.model = {}
  cases[13].value.anchorOffset.w = 1

  for _, case in ipairs(cases) do
    local valid, err = FieldEmoteAssetCache.validateDescriptor(case.value)
    Assert.isFalse(valid, case.name .. " must fail field-emote descriptor validation")
    Assert.isTrue(Errors.is(err), case.name .. " must return a structured validation error")
    if case.name == "invalid nested model" then
      err = assert(err)
      Assert.equal(err.code, ModelAsset.ERROR_INVALID, "nested model validation must retain its owner")
    end

    if case.name ~= "nan z" and case.name ~= "positive infinity x" and case.name ~= "negative infinity y" then
      Assert.isFalse(
        FieldEmoteAssetCache.isReady(cacheWith(case.value), MARKER),
        case.name .. " must not pass field-emote readiness"
      )
    end
  end
end

return T
