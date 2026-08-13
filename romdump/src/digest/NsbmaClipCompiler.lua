-- NsbmaClipCompiler: compiles a decoded NSBMA resource into the data-only
-- clip the runtime material evaluator samples. The engine never touches
-- NSBMA bytes; this module projects every channel flag and key into plain
-- numbers, and the engine's CompiledNsbmaSampler reproduces the Nitro
-- sampling math over that data. The two must stay in lockstep -- the
-- cross-check test samples every fixture through both paths and requires
-- bit-identical results.
--
-- The compiled clip carries the engine-neutral clip envelope plus a
-- `compiled` payload:
--
--   compiled = {
--     targets = { { index, name, channels = {
--       diffuse, ambient, specular, emission, alpha } } },
--   }
--
-- where each channel is
--   { source = "constant", value = n }    -- value = (flag >> 16) & 0xFFFF
--   { source = "curve", rate = 1|2|4, limit, isAlpha, keys = { ... } }
--     -- color keys raw u16 RGB555, alpha keys raw u8 (0..31)
--
-- Every channel carries data: a nil slot or a zero key offset raises
-- NSBMA_COMPILE_ABSENT_CHANNEL -- the compiled payload has no "absent"
-- state, and the corpus census proves no real member needs one (the DS
-- reads garbage for such a flag). Pure domain module.

local Errors = require("libs.errors.src.Errors")
local AnimationClip = require("libs.assets.src.AnimationClip")

local NsbmaClipCompiler = {}

local CONSTANT = "constant"
local CURVE = "curve"

-- Collect the key-array bounds: each curve channel's keys end where the
-- next curve channel's keys begin (channels share the record tail in
-- fixture and real layouts alike). The channel's ofs is record-relative,
-- like the decoder's.
local function keyBounds(res)
  local bases = {}
  for _, target in ipairs(res.targets) do
    for _, chan in pairs(target.channels) do
      if chan.source == CURVE then
        bases[res.record + chan.ofs] = true
      end
    end
  end
  local sorted = {}
  for base in pairs(bases) do
    sorted[#sorted + 1] = base
  end
  table.sort(sorted)
  local bounds = {}
  for i, base in ipairs(sorted) do
    bounds[base] = sorted[i + 1]
  end
  return bounds
end

-- Read every key of one curve channel: u16 colors or u8 alphas. The count
-- follows the channel's limit field (the authored array length for real
-- members), tightened by the next channel's key base when one follows.
-- `base` is the absolute key-array offset (record + ofs).
local function readKeys(reader, chan, base, nextBase, sectionLimit)
  local keys = {}
  local stride = chan.isAlpha and 1 or 2
  local byteCount = sectionLimit - base
  if nextBase then
    byteCount = math.min(byteCount, nextBase - base)
  end
  local count = math.min(chan.limit, math.floor(byteCount / stride))
  for i = 0, count - 1 do
    local at = base + i * stride
    reader:assertRange(at, stride, "nsbma-curve-key")
    keys[i + 1] = chan.isAlpha and reader:u8(at) or reader:u16le(at)
  end
  return keys
end

-- Project one decoded channel into its compiled form, attaching the curve's
-- key array. A channel with no data (nil slot or zero key offset) raises
-- NSBMA_COMPILE_ABSENT_CHANNEL: the compiled payload has no "absent" state,
-- and the corpus census proves no real member carries one. The compiled key
-- base is absolute (record + ofs).
local function raiseAbsent(ctx, reason)
  Errors.raise(
    "NSBMA_COMPILE_ABSENT_CHANNEL",
    "NSBMA clip " .. ctx.clip .. " target " .. tostring(ctx.target) .. " channel " .. ctx.channel .. " " .. reason,
    ctx
  )
end

local function copyChannel(chan, reader, bounds, record, sectionLimit, ctx)
  if not chan then
    raiseAbsent(ctx, "has no channel data")
  end
  if chan.source == CONSTANT then
    return { source = CONSTANT, value = chan.value }
  end
  if chan.ofs == 0 then
    raiseAbsent(ctx, "has a zero key offset")
  end
  local base = record + chan.ofs
  return {
    source = CURVE,
    rate = chan.rate,
    limit = chan.limit,
    isAlpha = chan.isAlpha,
    keys = readKeys(reader, chan, base, bounds[base], sectionLimit),
  }
end

-- Compile `res` (a decoded NSBMA record) into the compiled payload. `reader`
-- is the BinaryReader over the MAT0 section; `sectionLimit` the section's
-- byte length.
function NsbmaClipCompiler.compilePayload(res, reader, sectionLimit, clipId)
  assert(type(res) == "table" and res.targets ~= nil, "NsbmaClipCompiler requires a decoded NSBMA record")
  assert(reader ~= nil and sectionLimit ~= nil, "NsbmaClipCompiler requires the section reader and limit")

  local bounds = keyBounds(res)
  local targets = {}
  for _, target in ipairs(res.targets) do
    local channels = {}
    for _, name in ipairs({ "diffuse", "ambient", "specular", "emission", "alpha" }) do
      channels[name] = copyChannel(target.channels[name], reader, bounds, res.record, sectionLimit, {
        clip = clipId or "nsbma",
        target = target.index,
        channel = name,
      })
    end
    targets[#targets + 1] = { index = target.index, name = target.name, channels = channels }
  end
  return { targets = targets }
end

-- Build the full clip record from a decoded NSBMA resource.
--   opts.name            the Nitro dictionary entry name
--   opts.id              unique clip id (e.g. "a106-12")
--   opts.semanticNames   semantic roles
--   opts.source          provenance block (archive, memberId, sha1)
function NsbmaClipCompiler.compile(res, reader, sectionLimit, opts)
  opts = opts or {}
  local payload = NsbmaClipCompiler.compilePayload(res, reader, sectionLimit, opts.id)
  local tracks = {}
  for i, target in ipairs(payload.targets) do
    tracks[#tracks + 1] = { target = target.name, targetIndex = i - 1 }
  end
  return {
    id = opts.id or "nsbma",
    name = opts.name or "nsbma",
    category = AnimationClip.CATEGORIES.material,
    kind = AnimationClip.KINDS.COLOR,
    frameCount = res.numFrame,
    tracks = tracks,
    semanticNames = opts.semanticNames or {},
    source = opts.source or { type = "nitro", format = "NSBMA" },
    compiled = payload,
  }
end

return NsbmaClipCompiler
