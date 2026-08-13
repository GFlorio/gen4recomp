-- NsbtpClipCompiler: compiles a decoded NSBTP resource into the data-only
-- clip the runtime material evaluator samples. The engine never touches
-- NSBTP bytes; this module projects the target keys and the texture/palette
-- name tables into plain data, and the engine's CompiledNsbtpSampler
-- reproduces the key selection over it. The two must stay in lockstep --
-- the cross-check test compares both paths on every fixture.
--
-- The compiled clip carries the engine-neutral clip envelope plus a
-- `compiled` payload:
--
--   compiled = {
--     textureNames = { ... }, paletteNames = { ... },
--     targets = { { index, name, rate, keys = {
--       { frame, texIdx, plttIdx } } } },
--   }
--
-- The arrays are the counts: the payload carries no redundant
-- keyCount/numTextures/numPalettes (the sampler trusts #keys,
-- #textureNames, #paletteNames).
--
-- Texture/palette names are the runtime binding key: the material evaluator
-- resolves each variant texture/palette by name against the model's texture
-- set (the embedded TEX0 for real field models). Pure domain module.

local AnimationClip = require("libs.assets.src.AnimationClip")

local NsbtpClipCompiler = {}

-- Compile `res` (a decoded NSBTP record) into the compiled payload.
function NsbtpClipCompiler.compilePayload(res)
  assert(type(res) == "table" and res.targets ~= nil, "NsbtpClipCompiler requires a decoded NSBTP record")
  local targets = {}
  for _, target in ipairs(res.targets) do
    local keys = {}
    for _, key in ipairs(target.keys) do
      keys[#keys + 1] = { frame = key.frame, texIdx = key.texIdx, plttIdx = key.plttIdx }
    end
    targets[#targets + 1] = {
      index = target.index,
      name = target.name,
      rate = target.rate,
      keys = keys,
    }
  end
  return {
    textureNames = res.textureNames,
    paletteNames = res.paletteNames,
    targets = targets,
  }
end

-- Build the full clip record from a decoded NSBTP resource.
--   opts.name            the Nitro dictionary entry name
--   opts.id              unique clip id (e.g. "a106-12")
--   opts.semanticNames   semantic roles
--   opts.source          provenance block (archive, memberId, sha1)
function NsbtpClipCompiler.compile(res, opts)
  opts = opts or {}
  local payload = NsbtpClipCompiler.compilePayload(res)
  local tracks = {}
  for i, target in ipairs(payload.targets) do
    tracks[#tracks + 1] = { target = target.name, targetIndex = i - 1 }
  end
  return {
    id = opts.id or "nsbtp",
    name = opts.name or "nsbtp",
    category = AnimationClip.CATEGORIES.material,
    kind = AnimationClip.KINDS.PATTERN,
    frameCount = res.numFrame,
    tracks = tracks,
    semanticNames = opts.semanticNames or {},
    source = opts.source or { type = "nitro", format = "NSBTP" },
    compiled = payload,
  }
end

return NsbtpClipCompiler
