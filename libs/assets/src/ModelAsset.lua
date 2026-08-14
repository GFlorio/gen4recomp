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
-- ModelAsset.validate is the authoritative artifact gate: it covers the full
-- serialized contract -- the shared polygon draw state on every batch, the
-- per-kind material records (scene-form for static, the DS-register shape
-- for dynamic), and the per-kind compiled clip payloads the samplers consume
-- (category/kind vocabulary, channel sources, curve rate/limit/storage and
-- key coverage, rotation-table ranges, pattern key indices). If validate
-- passed for the current schema version, the runtime constructors may assume
-- the serialized record is valid. Both MapAssetCache (readiness/reference
-- traversal) and MapCacheWriter (pre-publish validation) use this module, so
-- the writer/readiness and the loader cannot drift apart. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local AnimationClip = require("libs.assets.src.AnimationClip")
local CompiledNsbtaClip = require("libs.assets.src.CompiledNsbtaClip")
local PolygonState = require("libs.assets.src.PolygonState")
local Validate = require("libs.assets.src.Validate")

local ModelAsset = {}

ModelAsset.SCHEMA = "g4-model-v2"
ModelAsset.KINDS = { static = true, ["nitro-dynamic"] = true }

-- The four DS base-material registers a material's `colors` block carries
-- (the dynamic compiler emits the block per channel; the static path emits
-- no block).
---@type table<string, boolean>
ModelAsset.MATERIAL_COLOR_CHANNELS = { diffuse = true, ambient = true, specular = true, emission = true }

-- The sampler wrap vocabulary (the pool configures images with it).
local WRAP_MODES = { clamp = true, ["repeat"] = true }

-- The render classification vocabulary of the dynamic material contract.
local ALPHA_MODES = { opaque = true, mask = true, blend = true }

local function invalid(reason, context)
  Errors.raise("MODEL_DESC_INVALID", "model descriptor is malformed: " .. reason, {
    reason = reason,
    modelKey = context,
  })
end

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function checkWrap(m, where, desc)
  local wrap = m.wrap
  if type(wrap) ~= "table" or not WRAP_MODES[wrap.x] or not WRAP_MODES[wrap.y] then
    invalid(where .. " material requires a wrap { x, y } of clamp/repeat", desc.key)
  end
end

local function checkFlip(m, where, desc)
  local flip = m.flip
  if type(flip) ~= "table" or type(flip.x) ~= "boolean" or type(flip.y) ~= "boolean" then
    invalid(where .. " material requires flip { x, y } booleans", desc.key)
  end
end

-- The texture binding metadata: a bound texture carries its format (both
-- paths) and, for dynamic materials, its alpha usage; untextured materials
-- carry none (the compiler emits the trio together).
local function checkTextureBinding(m, where, desc, requireAlphaUsage)
  if m.texture ~= nil then
    if type(m.texture) ~= "string" or #m.texture == 0 then
      invalid(where .. " material has a non-string texture path", desc.key)
    end
    if not (isInteger(m.textureFormat) and m.textureFormat >= 0) then
      invalid(where .. " material texture carries no textureFormat", desc.key)
    end
    if requireAlphaUsage and (type(m.alphaUsage) ~= "table" or type(m.alphaUsage.hasZero) ~= "boolean") then
      invalid(where .. " material texture carries no alphaUsage", desc.key)
    end
  elseif m.textureFormat ~= nil then
    invalid(where .. " material carries a textureFormat without a texture", desc.key)
  end
end

local function checkSrt(m, where, desc)
  local srt = m.srt
  if type(srt) ~= "table" then
    return
  end
  for _, field in ipairs({ "transS", "transT", "scaleS", "scaleT" }) do
    if type(srt[field]) ~= "number" then
      invalid(where .. " material srt." .. field .. " must be a number", desc.key)
    end
  end
  local rot = srt.rot
  if rot ~= nil and (type(rot) ~= "table" or type(rot.sin) ~= "number" or type(rot.cos) ~= "number") then
    invalid(where .. " material srt.rot must be { sin, cos } numbers", desc.key)
  end
  for _, field in ipairs({ "transOne", "rotOne", "scaleOne" }) do
    if type(srt[field]) ~= "boolean" then
      invalid(where .. " material srt." .. field .. " must be a boolean", desc.key)
    end
  end
end

local function checkVariants(m, where, desc)
  if m.variants ~= nil then
    if not Validate.isArray(m.variants) then
      invalid(where .. " material variants is not an array", desc.key)
    end
    for _, variant in ipairs(m.variants) do
      if type(variant) ~= "table" or type(variant.name) ~= "string" or #variant.name == 0 then
        invalid(where .. " material variant requires a name", desc.key)
      end
      -- A variant may be untextured: a pattern key whose texture the model's
      -- embedded TEX0 does not define still selects a variant, and it draws
      -- untextured exactly as the DS does.
      if variant.texture ~= nil and type(variant.texture) ~= "string" then
        invalid(where .. " material variant has a non-string texture path", desc.key)
      end
      for _, field in ipairs({ "width", "height" }) do
        if variant[field] ~= nil and not (type(variant[field]) == "number" and variant[field] >= 0) then
          invalid(where .. " material variant " .. variant.name .. " " .. field .. " must be non-negative", desc.key)
        end
      end
    end
  end
end

-- The optional four-channel colors block: {diffuse|ambient|specular|
-- emission} -> { r, g, b } integers in 0..255, the shape the dynamic
-- compiler emits from the DS base-material registers.
local function checkColors(m, where, desc, required)
  local colors = m.colors
  if colors == nil then
    if required then
      invalid(where .. " material requires the colors block", desc.key)
    end
    return
  end
  if type(colors) ~= "table" then
    invalid(where .. " material colors must be a table", desc.key)
  end
  for name, color in pairs(colors) do
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

-- The scene-form material record the static path emits: id/name, the sampler
-- state, and the bound-texture metadata. The dynamic path's records add the
-- DS register block and the render fields (see checkDynamicMaterial).
local function checkStaticMaterial(m, where, desc)
  if type(m) ~= "table" then
    invalid(where .. " material is not a record", desc.key)
  end
  if not Validate.isNonNegativeInteger(m.id) then
    invalid(where .. " material requires an id", desc.key)
  end
  if type(m.name) ~= "string" or #m.name == 0 then
    invalid(where .. " material requires a name", desc.key)
  end
  checkWrap(m, where, desc)
  checkFlip(m, where, desc)
  local diffuse = m.diffuse
  if
    type(diffuse) ~= "table"
    or not Validate.isNonNegativeInteger(diffuse.r)
    or not Validate.isNonNegativeInteger(diffuse.g)
    or not Validate.isNonNegativeInteger(diffuse.b)
  then
    invalid(where .. " material requires a diffuse { r, g, b } record", desc.key)
  end
  checkTextureBinding(m, where, desc, false)
end

-- The dynamic material record: the DS base-material registers (baseColor +
-- the per-channel colors block), the render classification fields, and the
-- sampler state. Every field is required -- the runtime never defaults them.
local function checkDynamicMaterial(m, where, desc)
  checkStaticMaterial(m, where, desc)
  local base = m.baseColor
  if
    type(base) ~= "table"
    or not Validate.isNonNegativeInteger(base.r)
    or base.r > 255
    or not Validate.isNonNegativeInteger(base.g)
    or base.g > 255
    or not Validate.isNonNegativeInteger(base.b)
    or base.b > 255
    or not Validate.isNonNegativeInteger(base.a)
    or base.a > 255
  then
    invalid(where .. " material baseColor must be { r, g, b, a } integers in 0..255", desc.key)
  end
  checkColors(m, where, desc, true)
  if not ALPHA_MODES[m.alphaMode] then
    invalid(where .. " material alphaMode must be opaque, mask, or blend", desc.key)
  end
  if type(m.doubleSided) ~= "boolean" then
    invalid(where .. " material doubleSided must be a boolean", desc.key)
  end
  if not (isInteger(m.polygonAlpha) and m.polygonAlpha >= 0 and m.polygonAlpha <= 31) then
    invalid(where .. " material polygonAlpha must be an integer in 0..31", desc.key)
  end
  if not (isInteger(m.texMtxMode) and m.texMtxMode >= 0 and m.texMtxMode <= 3) then
    invalid(where .. " material texMtxMode must be an integer in 0..3", desc.key)
  end
  for _, field in ipairs({ "texWidth", "texHeight" }) do
    if not (type(m[field]) == "number" and m[field] >= 0) then
      invalid(where .. " material " .. field .. " must be a non-negative number", desc.key)
    end
  end
  checkTextureBinding(m, where, desc, true)
  checkSrt(m, where, desc)
  if m.srtMatrix ~= nil and type(m.srtMatrix) ~= "table" then
    invalid(where .. " material srtMatrix must be a table", desc.key)
  end
  checkVariants(m, where, desc)
end

-- ---- compiled clip payloads ----
--
-- The payload shape follows the clip kind; the samplers consume exactly
-- these shapes, so a payload that validates here cannot fail a sampler
-- structurally. Each curve carries source/rate/limit/storage/keys; the
-- rotation tables are compiled to the highest entry the keys reference, so
-- every key must fall inside its table.

local CURVE_RATES = { [1] = true, [2] = true, [4] = true }
local STORAGES = { fx16 = true, fx32 = true }

-- The clip-kind strings the compilers stamp (AnimationClip.KINDS is keyed
-- by constant name; the serialized records carry the values).
local KIND_STRINGS = {}
for _, kind in pairs(AnimationClip.KINDS) do
  KIND_STRINGS[kind] = true
end

-- Channel source vocabularies: the full set (NSBCA's model/constant/curve)
-- and the material-animation set (constant/curve -- NSBTA/NSBMA have no
-- model source, and the samplers reject one).
local SOURCES_WITH_MODEL = { model = true, constant = true, curve = true }
local SOURCES_PLAIN = { constant = true, curve = true }
local SOURCE_LISTS = {
  withModel = { "model", "constant", "curve" },
  plain = { "constant", "curve" },
}

-- One compiled curve channel: { source = "curve", rate, limit, storage,
-- keys }. `pairKeys` allows scale-pair tables ({ scale, inverse }) in the
-- key array; `limitIsFrameCount` requires limit == the clip's frameCount
-- (the NSBCA/NSBTA corpus invariant).
local function checkCurve(channel, where, desc, opts)
  opts = opts or {}
  if not CURVE_RATES[channel.rate] then
    invalid(where .. " curve rate must be 1, 2, or 4", desc.key)
  end
  if not (isInteger(channel.limit) and channel.limit >= 1) then
    invalid(where .. " curve limit must be a positive integer", desc.key)
  end
  if opts.limitIsFrameCount and channel.limit ~= opts.frameCount then
    invalid(where .. " curve limit must equal the clip frameCount", desc.key)
  end
  if opts.storage and not STORAGES[channel.storage] then
    invalid(where .. " curve storage must be fx16 or fx32", desc.key)
  end
  if not Validate.isArray(channel.keys) or #channel.keys == 0 then
    invalid(where .. " curve requires a non-empty keys array", desc.key)
  end
  for i, key in ipairs(channel.keys) do
    local valid = type(key) == "number"
    if opts.pairKeys and not valid then
      valid = Validate.isArray(key) and #key == 2 and type(key[1]) == "number" and type(key[2]) == "number"
    end
    if not valid then
      invalid(where .. " curve key " .. i .. " is not a number", desc.key)
    end
  end
end

local function checkChannel(channel, where, desc, sources, curveOpts)
  if type(channel) ~= "table" or not sources[channel.source] then
    invalid(where .. " channel source must be one of " .. table.concat(curveOpts.sources, "/"), desc.key)
  end
  if channel.source == "constant" and type(channel.value) ~= "number" then
    invalid(where .. " constant channel requires a numeric value", desc.key)
  end
  if channel.source == "curve" then
    checkCurve(channel, where, desc, curveOpts)
  end
end

-- ---- per-kind payload checks ----

-- NSBCA (trs): anmFlags, the pivot/compressed rotation tables, and one
-- target per clip track; each channel is model/constant/curve, and the
-- rotation keys must fall inside the compiled tables.
local function checkTrsPayload(compiled, clip, desc)
  local where = "animation " .. clip.id
  if not isInteger(compiled.anmFlags) then
    invalid(where .. " compiled payload requires an anmFlags integer", desc.key)
  end
  if not Validate.isArray(compiled.rotData) or not Validate.isArray(compiled.pivotData) then
    invalid(where .. " compiled payload requires the rotation tables", desc.key)
  end
  for i, entry in ipairs(compiled.rotData) do
    if
      type(entry) ~= "table"
      or not (isInteger(entry.control) and entry.control >= 0)
      or type(entry.a) ~= "number"
      or type(entry.b) ~= "number"
    then
      invalid(where .. " rotData entry " .. i .. " must be { control, a, b }", desc.key)
    end
    if entry.control % 16 > 8 then
      invalid(where .. " rotData entry " .. i .. " pivot index exceeds 8", desc.key)
    end
  end
  for i, entry in ipairs(compiled.pivotData) do
    if not Validate.isArray(entry) or #entry ~= 5 then
      invalid(where .. " pivotData entry " .. i .. " must be a 5-cell array", desc.key)
    end
    for k = 1, 5 do
      if type(entry[k]) ~= "number" then
        invalid(where .. " pivotData entry " .. i .. " cell " .. k .. " must be a number", desc.key)
      end
    end
  end
  if not Validate.isArray(compiled.targets) or #compiled.targets ~= #clip.tracks then
    invalid(where .. " compiled payload must carry one target per track", desc.key)
  end
  for i, target in ipairs(compiled.targets) do
    local whereT = where .. " target " .. i
    if not Validate.isNonNegativeInteger(target.nodeIndex) then
      invalid(whereT .. " requires a nodeIndex", desc.key)
    end
    local channels = target.channels
    if type(channels) ~= "table" then
      invalid(whereT .. " requires channels", desc.key)
    end
    local curveOpts =
      { sources = SOURCE_LISTS.withModel, limitIsFrameCount = true, storage = true, frameCount = clip.frameCount }
    local pairOpts = {
      sources = SOURCE_LISTS.withModel,
      limitIsFrameCount = true,
      storage = true,
      frameCount = clip.frameCount,
      pairKeys = true,
    }
    for _, axis in ipairs({ "x", "y", "z" }) do
      checkChannel(
        channels.trans and channels.trans[axis],
        whereT .. " trans." .. axis,
        desc,
        SOURCES_WITH_MODEL,
        curveOpts
      )
    end
    checkChannel(channels.rot, whereT .. " rot", desc, SOURCES_WITH_MODEL, curveOpts)
    for _, axis in ipairs({ "x", "y", "z" }) do
      local scale = channels.scale and channels.scale[axis]
      checkChannel(scale, whereT .. " scale." .. axis, desc, SOURCES_WITH_MODEL, pairOpts)
      if scale and scale.source == "constant" and scale.inverse ~= nil and type(scale.inverse) ~= "number" then
        invalid(whereT .. " scale." .. axis .. " inverse must be a number", desc.key)
      end
    end
  end
  -- The rotation tables are compiled to the highest key the clip references,
  -- so every rotation key (constant or curve) must land inside its table.
  for _, target in ipairs(compiled.targets) do
    local channels = target.channels
    local function checkRotKey(value)
      if not (isInteger(value) and value >= 0) then
        invalid(where .. " rotation key must be a u16 integer", desc.key)
      end
      local index = value % 32768
      if value >= 0x8000 then
        if not compiled.rotData[index + 1] then
          invalid(where .. " rotation key " .. tostring(value) .. " is beyond the compiled pivot table", desc.key)
        end
      elseif not compiled.pivotData[index + 1] then
        invalid(where .. " rotation key " .. tostring(value) .. " is beyond the compiled compressed table", desc.key)
      end
    end
    local rot = channels.rot
    if rot.source == "constant" then
      checkRotKey(rot.value)
    elseif rot.source == "curve" then
      if #rot.keys < math.ceil(clip.frameCount / rot.rate) then
        invalid(where .. " rotation curve carries fewer keys than its frames demand", desc.key)
      end
      for _, key in ipairs(rot.keys) do
        checkRotKey(key)
      end
    end
    -- The trans/scale curves must cover their frames too: the sampler walks
    -- the key array by frame, so a shorter array would read past the end.
    for _, axis in ipairs({ "x", "y", "z" }) do
      local channel = channels.trans[axis]
      if channel and channel.source == "curve" and #channel.keys < math.ceil(clip.frameCount / channel.rate) then
        invalid(where .. " trans." .. axis .. " curve carries fewer keys than its frames demand", desc.key)
      end
    end
    for _, axis in ipairs({ "x", "y", "z" }) do
      local channel = channels.scale[axis]
      if channel and channel.source == "curve" and #channel.keys < math.ceil(clip.frameCount / channel.rate) then
        invalid(where .. " scale." .. axis .. " curve carries fewer keys than its frames demand", desc.key)
      end
    end
  end
end

-- NSBTA (texsrt): the compiled payload contract is the shared validator's
-- (five texture-SRT channels per target, exact curve key coverage, and
-- unique track targets); ModelAsset reports its violations under
-- MODEL_DESC_INVALID.

-- NSBMA (color): one target per track, each carrying the five material
-- registers (diffuse/ambient/specular/emission/alpha).
local function checkColorPayload(compiled, clip, desc)
  local where = "animation " .. clip.id
  if not Validate.isArray(compiled.targets) or #compiled.targets ~= #clip.tracks then
    invalid(where .. " compiled payload must carry one target per track", desc.key)
  end
  for i, target in ipairs(compiled.targets) do
    local whereT = where .. " target " .. i
    if type(target.name) ~= "string" or not Validate.isNonNegativeInteger(target.index) then
      invalid(whereT .. " requires a name and index", desc.key)
    end
    local channels = target.channels
    if type(channels) ~= "table" then
      invalid(whereT .. " requires channels", desc.key)
    end
    local plain = { sources = SOURCE_LISTS.plain }
    for _, name in ipairs({ "diffuse", "ambient", "specular", "emission", "alpha" }) do
      checkChannel(channels[name], whereT .. " " .. name, desc, SOURCES_PLAIN, plain)
    end
  end
end

-- NSBTP (pattern): the texture/palette name tables and one target per track,
-- whose keys index them. The payload trusts its arrays: no redundant
-- keyCount/numTextures/numPalettes counts are carried.
local function checkPatternPayload(compiled, clip, desc)
  local where = "animation " .. clip.id
  if not Validate.isArray(compiled.textureNames) or #compiled.textureNames == 0 then
    invalid(where .. " compiled payload requires non-empty textureNames", desc.key)
  end
  for i, name in ipairs(compiled.textureNames) do
    if type(name) ~= "string" then
      invalid(where .. " textureNames[" .. i .. "] must be a string", desc.key)
    end
  end
  if not Validate.isArray(compiled.paletteNames) then
    invalid(where .. " compiled payload requires a paletteNames array", desc.key)
  end
  for i, name in ipairs(compiled.paletteNames) do
    if type(name) ~= "string" then
      invalid(where .. " paletteNames[" .. i .. "] must be a string", desc.key)
    end
  end
  if not Validate.isArray(compiled.targets) or #compiled.targets ~= #clip.tracks then
    invalid(where .. " compiled payload must carry one target per track", desc.key)
  end
  for i, target in ipairs(compiled.targets) do
    local whereT = where .. " target " .. i
    if type(target.name) ~= "string" or not Validate.isNonNegativeInteger(target.index) then
      invalid(whereT .. " requires a name and index", desc.key)
    end
    if not Validate.isNonNegativeInteger(target.rate) then
      invalid(whereT .. " requires a rate", desc.key)
    end
    if not Validate.isArray(target.keys) or #target.keys == 0 then
      invalid(whereT .. " requires a non-empty keys array", desc.key)
    end
    for _, key in ipairs(target.keys) do
      if
        type(key) ~= "table"
        or not Validate.isNonNegativeInteger(key.frame)
        or not Validate.isNonNegativeInteger(key.texIdx)
        or not Validate.isNonNegativeInteger(key.plttIdx)
      then
        invalid(whereT .. " key record must be { frame, texIdx, plttIdx } non-negative integers", desc.key)
      end
      if not compiled.textureNames[key.texIdx + 1] then
        invalid(
          whereT .. " key texture index " .. tostring(key.texIdx) .. " is beyond the compiled texture list",
          desc.key
        )
      end
      if key.plttIdx ~= 0xFF and not compiled.paletteNames[key.plttIdx + 1] then
        invalid(
          whereT .. " key palette index " .. tostring(key.plttIdx) .. " is beyond the compiled palette list",
          desc.key
        )
      end
    end
  end
end

-- The clip envelope plus the per-kind compiled payload: the category and
-- kind vocabularies are the animation contract's (libs/assets owns them), and
-- the payload shape follows the kind, so a clip whose payload does not match
-- its kind is malformed generated data.
local function checkAnimation(clip, desc)
  local where = "animation " .. tostring(clip.id)
  if
    type(clip) ~= "table"
    or type(clip.id) ~= "string"
    or #clip.id == 0
    or type(clip.name) ~= "string"
    or #clip.name == 0
    or not AnimationClip.CATEGORIES[clip.category]
    or not KIND_STRINGS[clip.kind]
    or not (type(clip.frameCount) == "number" and clip.frameCount >= 1 and clip.frameCount % 1 == 0)
    or not Validate.isArray(clip.tracks)
    or #clip.tracks == 0
    or not Validate.isArray(clip.semanticNames)
  then
    invalid(
      "animation clip must carry id, name, a known category/kind, frameCount, tracks, and semanticNames",
      desc.key
    )
  end
  for _, semantic in ipairs(clip.semanticNames) do
    if type(semantic) ~= "string" or #semantic == 0 then
      invalid(where .. " semantic names must be non-empty strings", desc.key)
    end
  end
  if type(clip.compiled) ~= "table" then
    invalid(where .. " requires a compiled payload table", desc.key)
  end
  if clip.kind == AnimationClip.KINDS.TRS then
    checkTrsPayload(clip.compiled, clip, desc)
  elseif clip.kind == AnimationClip.KINDS.TEXSRT then
    CompiledNsbtaClip.validate(clip, function(reason)
      invalid(where .. ": " .. reason, desc.key)
    end)
  elseif clip.kind == AnimationClip.KINDS.COLOR then
    checkColorPayload(clip.compiled, clip, desc)
  elseif clip.kind == AnimationClip.KINDS.PATTERN then
    checkPatternPayload(clip.compiled, clip, desc)
  end
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

  -- Material ids are the list positions (the compiler assigns each material
  -- its index, and the runtime indexes material state by position), so a
  -- record whose id is not its position is malformed generated data.
  local function checkMaterialIndices(where)
    for i, m in ipairs(desc.materials) do
      if m.id ~= i - 1 then
        invalid(
          where .. " materials must be contiguous zero-based indices; material " .. i .. " has id " .. tostring(m.id),
          desc.key
        )
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
      checkStaticMaterial(m, "static", desc)
    end
    checkMaterialIndices("static")
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
    checkDynamicMaterial(m, "dynamic", desc)
  end
  checkMaterialIndices("dynamic")
  for _, clip in ipairs(desc.animations) do
    checkAnimation(clip, desc)
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
