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
local PolygonState = require("libs.assets.src.PolygonState")
local Validate = require("libs.assets.src.Validate")

local ModelAsset = {}

ModelAsset.SCHEMA = "g4-model-v2"
ModelAsset.KINDS = { static = true, ["nitro-dynamic"] = true }

-- The four DS base-material registers a material's optional `colors` block
-- may carry (the dynamic compiler emits the block per channel; the static
-- path emits no block and the shared evaluator falls back to baseColor).
---@type table<string, boolean>
ModelAsset.MATERIAL_COLOR_CHANNELS = { diffuse = true, ambient = true, specular = true, emission = true }

local function invalid(reason, context)
  Errors.raise("MODEL_DESC_INVALID", "model descriptor is malformed: " .. reason, {
    reason = reason,
    modelKey = context,
  })
end

-- Validate one descriptor record strictly. Raises MODEL_DESC_INVALID on any
-- contract violation. The authoritative artifact gate: MapCacheWriter runs
-- every compiled descriptor through this before publishing, and the emitted
-- shape (both batch kinds carry the full polygon draw-state field set) must
-- validate -- a malformed variant is diagnosed here, never defaulted at the
-- load boundary.
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

  -- Every batch of either kind requires the full shared draw-state field set
  -- with the range checks (PolygonState is the single schema source); the
  -- asset boundary reports violations under its own error contract.
  local function checkBatch(b, where)
    if type(b) ~= "table" or type(b.geometry) ~= "string" then
      invalid(where .. " batch does not reference a geometry path", desc.key)
    end
    local ok, err = pcall(PolygonState.validate, b, where .. " batch")
    if not ok then
      -- The asset boundary reports polygon-state violations under its own
      -- error contract; anything else is a fault and re-raises.
      if Errors.is(err) then
        invalid(Errors.format(err), desc.key)
      end
      error(err)
    end
  end
  -- Dynamic batches additionally reference the model's nodes and materials
  -- by index and carry the draw id the runtime keyed meshes by.
  local function checkDynamicBatch(b)
    checkBatch(b, "dynamic")
    if type(b.id) ~= "string" or #b.id == 0 then
      invalid("dynamic batch requires a non-empty id", desc.key)
    end
    if not Validate.isNonNegativeInteger(b.drawIndex) then
      invalid("dynamic batch " .. tostring(b.id) .. " drawIndex must be a non-negative integer", desc.key)
    end
    if not (Validate.isNonNegativeInteger(b.nodeIndex) and b.nodeIndex < #desc.dynamic.nodes) then
      invalid("dynamic batch " .. tostring(b.id) .. " nodeIndex is out of range", desc.key)
    end
    if not (Validate.isNonNegativeInteger(b.materialIndex) and b.materialIndex < #desc.materials) then
      invalid("dynamic batch " .. tostring(b.id) .. " materialIndex is out of range", desc.key)
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
        if type(variant) ~= "table" then
          invalid(where .. " material variant is not a record", desc.key)
        end
        -- A variant may be untextured: a pattern key whose texture the model's
        -- embedded TEX0 does not define still selects a variant, and it draws
        -- untextured exactly as the DS does.
        if variant.texture ~= nil and type(variant.texture) ~= "string" then
          invalid(where .. " material variant has a non-string texture path", desc.key)
        end
      end
    end
    -- The optional four-channel colors block: {diffuse|ambient|specular|
    -- emission} -> { r, g, b } integers in 0..255, the shape the dynamic
    -- compiler emits from the DS base-material registers.
    if m.colors ~= nil then
      if type(m.colors) ~= "table" then
        invalid(where .. " material colors must be a table", desc.key)
      end
      for name, color in pairs(m.colors) do
        if not ModelAsset.MATERIAL_COLOR_CHANNELS[name] then
          invalid(where .. " material colors carries an unknown channel " .. tostring(name), desc.key)
        end
        if
          type(color) ~= "table"
          or not Validate.isNonNegativeInteger(color.r)
          or color.r > 255
          or not Validate.isNonNegativeInteger(color.g)
          or color.g > 255
          or not Validate.isNonNegativeInteger(color.b)
          or color.b > 255
        then
          invalid(where .. " material colors." .. name .. " must be { r, g, b } integers in 0..255", desc.key)
        end
      end
    end
  end
  -- The clip envelope every animation record must satisfy: id/name/category/
  -- frameCount/tracks. The category vocabulary and the compiled payload are
  -- the engine's clip contract (libs/assets must not require libs/engine),
  -- so the asset boundary checks shape only.
  local function checkAnimation(clip)
    if
      type(clip) ~= "table"
      or type(clip.id) ~= "string"
      or #clip.id == 0
      or type(clip.name) ~= "string"
      or #clip.name == 0
      or type(clip.category) ~= "string"
      or #clip.category == 0
      or not (type(clip.frameCount) == "number" and clip.frameCount >= 1 and clip.frameCount % 1 == 0)
      or not Validate.isArray(clip.tracks)
      or #clip.tracks == 0
    then
      invalid("animation clip must carry id, name, category, frameCount, and non-empty tracks", desc.key)
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
  local seenBatchIds = {}
  for _, b in ipairs(desc.dynamic.batches) do
    checkDynamicBatch(b)
    if seenBatchIds[b.id] then
      invalid("dynamic descriptor lists batch id " .. tostring(b.id) .. " twice", desc.key)
    end
    seenBatchIds[b.id] = true
  end
  for _, m in ipairs(desc.materials) do
    checkMaterial(m, "dynamic")
  end
  for _, clip in ipairs(desc.animations) do
    checkAnimation(clip)
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
      if variant.texture then
        paths[#paths + 1] = variant.texture
      end
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
