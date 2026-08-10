-- Validation and reference traversal for the derived model descriptors
-- (the cache form MapAssetCompiler writes, keyed by content-addressed model
-- key under data/generated/models/). The descriptor contract is explicit:
-- every descriptor carries a schema and a kind, and each kind has its own
-- strict shape, so a malformed generated artifact is diagnosed instead of
-- being defaulted or distinguished by implicit field presence.
--
--   static:        { schema, key, memberId, kind = "static",
--                    batches = { { geometry, material, ... } }, materials }
--   nitro-dynamic: { schema, key, memberId, kind = "nitro-dynamic",
--                    dynamic = { nodes, transformProgram, batches }, materials,
--                    animations }
--
-- Both MapAssetCache (readiness/reference traversal) and MapCacheWriter
-- (pre-publish validation) use this module, so the writer/readiness and the
-- loader cannot drift apart. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local Validate = require("libs.assets.src.Validate")

local ModelAsset = {}

ModelAsset.SCHEMA = "g4-model-v2"
ModelAsset.KINDS = { static = true, ["nitro-dynamic"] = true }

local function invalid(reason, context)
  Errors.raise("MODEL_DESC_INVALID", "model descriptor is malformed: " .. reason, {
    reason = reason,
    modelKey = context,
  })
end

-- Validate one descriptor record strictly. Raises MODEL_DESC_INVALID on any
-- contract violation.
function ModelAsset.validate(desc)
  if type(desc) ~= "table" then
    invalid("descriptor is not a table")
  end
  if desc.schema ~= ModelAsset.SCHEMA then
    invalid("schema must be " .. ModelAsset.SCHEMA .. ", got " .. tostring(desc.schema), desc.key)
  end
  if not ModelAsset.KINDS[desc.kind] then
    invalid("kind must be static or nitro-dynamic, got " .. tostring(desc.kind), desc.key)
  end

  local function checkBatch(b, where)
    if type(b) ~= "table" or type(b.geometry) ~= "string" then
      invalid(where .. " batch does not reference a geometry path", desc.key)
    end
  end
  local function checkMaterial(m, where)
    if type(m) ~= "table" then
      invalid(where .. " material is not a record", desc.key)
    end
    if m.texture ~= nil and type(m.texture) ~= "string" then
      invalid(where .. " material has a non-string texture path", desc.key)
    end
    if m.variants ~= nil then
      if not Validate.isArray(m.variants) then
        invalid(where .. " material variants is not an array", desc.key)
      end
      for _, variant in ipairs(m.variants) do
        if type(variant) ~= "table" or type(variant.texture) ~= "string" then
          invalid(where .. " material variant does not reference a texture path", desc.key)
        end
      end
    end
  end

  if desc.kind == "static" then
    if not Validate.isArray(desc.batches) then
      invalid("static descriptor requires a batches array", desc.key)
    end
    if not Validate.isArray(desc.materials) then
      invalid("static descriptor requires a materials array", desc.key)
    end
    for _, b in ipairs(desc.batches) do
      checkBatch(b, "static")
    end
    for _, m in ipairs(desc.materials) do
      checkMaterial(m, "static")
    end
    return desc
  end

  -- nitro-dynamic
  if type(desc.dynamic) ~= "table" then
    invalid("nitro-dynamic descriptor requires a dynamic block", desc.key)
  end
  if not Validate.isArray(desc.dynamic.nodes) then
    invalid("dynamic block requires a nodes array", desc.key)
  end
  if type(desc.dynamic.transformProgram) ~= "table" then
    invalid("dynamic block requires a transformProgram", desc.key)
  end
  if not Validate.isArray(desc.dynamic.batches) then
    invalid("dynamic block requires a batches array", desc.key)
  end
  if not Validate.isArray(desc.materials) then
    invalid("nitro-dynamic descriptor requires a materials array", desc.key)
  end
  if not Validate.isArray(desc.animations) then
    invalid("nitro-dynamic descriptor requires an animations array", desc.key)
  end
  for _, b in ipairs(desc.dynamic.batches) do
    checkBatch(b, "dynamic")
  end
  for _, m in ipairs(desc.materials) do
    checkMaterial(m, "dynamic")
  end
  return desc
end

-- Every cache-relative path a descriptor references: batch geometry, base
-- material textures, and pattern-variant textures (a variant PNG is a
-- referenced asset just like the base texture; readiness must cover it).
-- Raises MODEL_DESC_INVALID on a malformed descriptor.
function ModelAsset.referencedPaths(desc)
  ModelAsset.validate(desc)
  local paths = {}
  local function addBatch(b)
    paths[#paths + 1] = b.geometry
  end
  local function addMaterial(m)
    if m.texture then
      paths[#paths + 1] = m.texture
    end
    for _, variant in ipairs(m.variants or {}) do
      paths[#paths + 1] = variant.texture
    end
  end
  if desc.kind == "static" then
    for _, b in ipairs(desc.batches) do
      addBatch(b)
    end
    for _, m in ipairs(desc.materials) do
      addMaterial(m)
    end
  else
    for _, b in ipairs(desc.dynamic.batches) do
      addBatch(b)
    end
    for _, m in ipairs(desc.materials) do
      addMaterial(m)
    end
  end
  return paths
end

return ModelAsset
