-- NsbtaClipCompiler: compiles a decoded NSBTA resource into the data-only
-- clip the runtime material evaluator samples. The engine never reads NSBTA
-- bytes; this module projects every channel and curve key into plain
-- numbers, and the engine's CompiledNsbtaSampler reproduces the Nitro
-- sampling math over that data. The two must stay in lockstep -- the
-- cross-check test samples every fixture through both paths and requires
-- bit-identical results.
--
-- The compiled clip carries the engine-neutral clip envelope (id, name,
-- category, frameCount, binding tracks, semantic names, provenance) plus a
-- `compiled` payload:
--
--   compiled = {
--     targets = { { index, name, channels = {
--       transS, transT, rot, scaleS, scaleT } } },
--   }
--
-- where each channel is
--   { source = "constant", value = u32 }     -- the ofs field IS the value
--   { source = "curve", rate, limit, storage, keys = { ... } }
--     -- raw words exactly as the decoder reads them: fx16 sign-extended,
--     -- fx32 raw u32, rotation keys always the packed u32 sin/cos words
--
-- Every channel carries data: a nil slot or a zero flag raises
-- NSBTA_COMPILE_ABSENT_CHANNEL -- the compiled payload has no "absent"
-- state, and the corpus census (99/99 NSBTA members) proves no real member
-- needs one; identity components are authored as explicit constants (scale
-- 0x1000, rotation identity word, translation 0). Pure domain module.

local Errors = require("libs.errors.src.Errors")
local AnimationClip = require("libs.assets.src.AnimationClip")

local NsbtaClipCompiler = {}

local function s16(value)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

local CONSTANT = "constant"
local CURVE = "curve"

-- Collect the key-array bounds: each curve channel's keys end where the
-- next curve channel's keys begin (channels share the record tail in
-- fixture and real layouts alike).
local function keyBounds(res)
  local bases = {}
  for _, target in ipairs(res.targets) do
    for _, name in ipairs({ "transS", "transT", "rot", "scaleS", "scaleT" }) do
      local chan = target.channels[name]
      if chan and chan.source == CURVE then
        bases[chan.ofs] = true
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

-- Read every key of one curve channel (its raw words, in storage order).
-- The count follows the channel's limit field (the authored array length
-- for real members), tightened by the next channel's key base when one
-- follows. `isRot` selects the packed u32 sin/cos words.
local function readKeys(reader, chan, nextBase, sectionLimit)
  local keys = {}
  local stride
  if chan.packedPair then
    stride = 4
  elseif chan.storage == "fx16" then
    stride = 2
  else
    stride = 4
  end
  local byteCount = sectionLimit - chan.ofs
  if nextBase then
    byteCount = math.min(byteCount, nextBase - chan.ofs)
  end
  local count = math.min(chan.limit, math.floor(byteCount / stride))
  for i = 0, count - 1 do
    local at = chan.ofs + i * stride
    reader:assertRange(at, stride, "nsbta-curve-key")
    if chan.packedPair then
      keys[i + 1] = reader:u32le(at)
    elseif chan.storage == "fx16" then
      keys[i + 1] = s16(reader:u16le(at))
    else
      keys[i + 1] = reader:u32le(at)
    end
  end
  return keys
end

-- Project one decoded channel into its compiled form, attaching the curve's
-- key array. A channel with no data (nil slot or zero flag) raises
-- NSBTA_COMPILE_ABSENT_CHANNEL: the compiled payload has no "absent" state,
-- and the corpus census proves no real member carries one -- identity
-- components are authored as explicit constants. A curve whose limit differs
-- from numFrame raises NSBTA_CURVE_LIMIT_MISMATCH: the corpus census
-- (217/217 curve channels across the 99 NSBTA members) records
-- limit == numFrame everywhere, and anything else is malformed data.
local function raiseAbsent(ctx, reason)
  Errors.raise(
    "NSBTA_COMPILE_ABSENT_CHANNEL",
    "NSBTA clip " .. ctx.clip .. " target " .. tostring(ctx.target) .. " channel " .. ctx.channel .. " " .. reason,
    ctx
  )
end

local function copyChannel(chan, reader, bounds, sectionLimit, ctx)
  if not chan then
    raiseAbsent(ctx, "has no channel data")
  end
  if chan.source == CONSTANT then
    return { source = CONSTANT, value = chan.value }
  end
  if chan.flagRaw == 0 then
    raiseAbsent(ctx, "has a zero flag")
  end
  if chan.limit ~= ctx.numFrame then
    Errors.raise(
      "NSBTA_CURVE_LIMIT_MISMATCH",
      "NSBTA clip "
        .. ctx.clip
        .. " target "
        .. tostring(ctx.target)
        .. " channel "
        .. ctx.channel
        .. " limit "
        .. tostring(chan.limit)
        .. " != numFrame "
        .. tostring(ctx.numFrame),
      { clip = ctx.clip, target = ctx.target, channel = ctx.channel, limit = chan.limit, numFrame = ctx.numFrame }
    )
  end
  return {
    source = CURVE,
    rate = chan.rate,
    limit = chan.limit,
    storage = chan.storage,
    keys = readKeys(reader, chan, bounds[chan.ofs], sectionLimit),
  }
end

-- Compile `res` (a decoded NSBTA record) into the compiled payload. `reader`
-- is the BinaryReader over the SRT0 section; `sectionLimit` the section's
-- byte length.
function NsbtaClipCompiler.compilePayload(res, reader, sectionLimit, clipId)
  assert(type(res) == "table" and res.targets ~= nil, "NsbtaClipCompiler requires a decoded NSBTA record")
  assert(reader ~= nil and sectionLimit ~= nil, "NsbtaClipCompiler requires the section reader and limit")

  local bounds = keyBounds(res)
  local targets = {}
  for _, target in ipairs(res.targets) do
    local channels = {}
    for _, name in ipairs({ "transS", "transT", "rot", "scaleS", "scaleT" }) do
      channels[name] = copyChannel(target.channels[name], reader, bounds, sectionLimit, {
        clip = clipId or "nsbta",
        target = target.index,
        channel = name,
        numFrame = res.numFrame,
      })
    end
    targets[#targets + 1] = { index = target.index, name = target.name, channels = channels }
  end
  return { targets = targets }
end

-- Build the full clip record from a decoded NSBTA resource.
--   opts.name            the Nitro dictionary entry name
--   opts.id              unique clip id (e.g. "a106-12")
--   opts.semanticNames   semantic roles (e.g. { "door.open" })
--   opts.source          provenance block (archive, memberId, sha1)
function NsbtaClipCompiler.compile(res, reader, sectionLimit, opts)
  opts = opts or {}
  local payload = NsbtaClipCompiler.compilePayload(res, reader, sectionLimit, opts.id)
  local tracks = {}
  for i, target in ipairs(payload.targets) do
    tracks[#tracks + 1] = { target = target.name, targetIndex = i - 1 }
  end
  return {
    id = opts.id or "nsbta",
    name = opts.name or "nsbta",
    category = AnimationClip.CATEGORIES.material,
    kind = AnimationClip.KINDS.TEXSRT,
    frameCount = res.numFrame,
    tracks = tracks,
    semanticNames = opts.semanticNames or {},
    source = opts.source or { type = "nitro", format = "NSBTA" },
    compiled = payload,
  }
end

return NsbtaClipCompiler
