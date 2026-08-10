-- ModelAsset: strict descriptor validation and reference traversal. An
-- untextured variant is a first-class output of the compiler -- a pattern key
-- the model's embedded TEX0 does not define still selects a variant, which
-- then draws untextured exactly as the DS does -- so validation must accept
-- it while still rejecting malformed records, and reference traversal must
-- not hand nil paths downstream.

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

return T
