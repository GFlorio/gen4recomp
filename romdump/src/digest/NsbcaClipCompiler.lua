-- NsbcaClipCompiler: compiles a decoded NSBCA resource into the data-only
-- clip the runtime Nitro pose backend samples. The engine never reads NSBCA
-- bytes; this module projects every channel, curve key, and rotation table
-- entry into plain numbers, and the engine's CompiledNsbcaSampler reproduces
-- the Nitro sampling math over that data. The two must stay in lockstep --
-- the cross-check test samples every fixture through both paths and requires
-- bit-identical results.
--
-- The compiled clip carries the engine-neutral clip envelope (id, name,
-- category, frameCount, binding tracks, semantic names, provenance) plus a
-- `compiled` payload:
--
--   compiled = {
--     anmFlags,                              -- fractional / wrap-final flags
--     rotData = { { control, a, b }, ... },  -- pivot entries (raw words)
--     pivotData = { { e1..e5 }, ... },       -- compressed entries
--     targets = { { nodeIndex, channels = {
--       trans = { x, y, z }, rot, scale = { x, y, z } } } },
--   }
--
-- where each channel is
--   { source = "model" }
--   { source = "constant", value = <raw u32> }       -- scale adds inverse
--   { source = "curve", rate, limit, storage, keys = { ... } }
--     -- keys hold the raw words exactly as the decoders read them: fx16
--     -- sign-extended, fx32 raw u32 (scale pairs { scale, inverse }), and
--     -- rotation keys always raw u16; limit always equals numFrame
--     -- (asserted at compile -- the corpus invariant)
--
-- The rotation tables are compiled up to the highest entry the clip's
-- rotation keys and constants reference (pivot and compressed forms
-- separately); a sampler fed a key beyond them raises, matching the
-- malformed-offset diagnostics of the decoders.
-- Pure domain module.

local Errors = require("libs.errors.src.Errors")
local AnimationClip = require("libs.assets.src.AnimationClip")

local NsbcaClipCompiler = {}

local function s16(value)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

local MODEL = "model"
local CONSTANT = "constant"
local CURVE = "curve"

-- The highest pivot/compressed table index the clip's rotation keys and
-- constants reference. Returns { pivot = n | nil, compressed = n | nil }.
local function rotTableNeeds(reader, targets, bounds, sectionLimit)
  local pivot, compressed
  local function note(value)
    local index = value % 32768
    if value >= 0x8000 then
      pivot = math.max(pivot or 0, index)
    else
      compressed = math.max(compressed or 0, index)
    end
  end
  for _, target in ipairs(targets) do
    local rot = target.channels.rot
    if rot.source == CONSTANT then
      note(rot.value)
    elseif rot.source == CURVE then
      -- Rotation keys are always u16 (the fx16 storage bit is ignored).
      local at = rot.curve.keyBase
      local limit = bounds[rot.curve.keyBase] or sectionLimit
      local count = math.floor((limit - at) / 2)
      for i = 0, count - 1 do
        note(reader:u16le(at + i * 2))
      end
    end
  end
  return { pivot = pivot, compressed = compressed }
end

-- Collect the key-array bounds: each curve channel's keys end where the
-- next curve channel's keys begin (channels share the record tail in
-- fixture and real layouts alike). Source-format invariant: the JNT0 key
-- area is laid out as contiguous, non-overlapping key arrays appended after
-- the target/rotation tables, and the FINAL curve's key array extends to
-- the end of the JNT0 section (there is no following offset to bound it),
-- so its limit is the section length. The compile order is by key base, so
-- the chaining holds regardless of the authoring order of the arrays.
local function keyBounds(res)
  local bases = {}
  for _, target in ipairs(res.targets) do
    local function note(channel)
      if channel and channel.source == CURVE then
        bases[channel.curve.keyBase] = true
      end
    end
    for _, axis in ipairs({ "x", "y", "z" }) do
      note(target.channels.trans[axis])
      note(target.channels.scale[axis])
    end
    note(target.channels.rot)
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
local function readKeys(reader, curve, limit, isRot)
  local keys = {}
  local stride
  if isRot then
    stride = 2 -- rotation keys are always raw u16, no sign extension
  elseif curve.storage == "fx16" then
    stride = 2
  else
    stride = 4
  end
  local count = math.floor((limit - curve.keyBase) / stride / curve.keysPerValue)
  for i = 0, count - 1 do
    local values = {}
    for k = 1, curve.keysPerValue do
      local at = curve.keyBase + i * stride * curve.keysPerValue + (k - 1) * stride
      reader:assertRange(at, stride, "anm-curve-key")
      if isRot then
        values[k] = reader:u16le(at)
      elseif curve.storage == "fx16" then
        values[k] = s16(reader:u16le(at))
      else
        values[k] = reader:u32le(at)
      end
    end
    keys[i + 1] = curve.keysPerValue == 2 and values or values[1]
  end
  return keys
end

-- Project one decoded channel into its compiled form, attaching the curve's
-- key array. `isRot` marks the rotation channel (raw u16 keys). A curve
-- whose limit differs from numFrame raises NSBCA_CURVE_LIMIT_MISMATCH: the
-- corpus invariant (verified for all 85 NSBCA members of the HGSS field
-- archive) is limit == numFrame, and anything else is either a different
-- title/resource or malformed data.
local function copyChannel(chan, reader, bounds, isRot, numFrame, ctx)
  if not chan then
    return nil
  end
  if chan.source == MODEL then
    return { source = MODEL }
  end
  if chan.source == CONSTANT then
    local out = { source = CONSTANT, value = chan.value }
    if chan.inverse ~= nil then
      out.inverse = chan.inverse
    end
    return out
  end
  local curve = chan.curve
  if curve.limit ~= numFrame then
    Errors.raise(
      "NSBCA_CURVE_LIMIT_MISMATCH",
      "NSBCA clip "
        .. ctx.clip
        .. " target "
        .. tostring(ctx.target)
        .. " channel "
        .. ctx.channel
        .. " limit "
        .. tostring(curve.limit)
        .. " != numFrame "
        .. tostring(numFrame),
      { clip = ctx.clip, target = ctx.target, channel = ctx.channel, limit = curve.limit, numFrame = numFrame }
    )
  end
  local limit = bounds[curve.keyBase] or bounds.sectionLimit
  return {
    source = CURVE,
    rate = curve.rate,
    limit = curve.limit,
    storage = isRot and "fx16" or curve.storage,
    keys = readKeys(reader, curve, limit, isRot),
  }
end

-- Compile `res` (a decoded NSBCA record) into the compiled payload. `reader`
-- is the BinaryReader over the JNT0 section; `sectionLimit` the section's
-- byte length; `clipId` names the clip in compile error contexts.
function NsbcaClipCompiler.compilePayload(res, reader, sectionLimit, clipId)
  assert(type(res) == "table" and res.targets ~= nil, "NsbcaClipCompiler requires a decoded NSBCA record")
  assert(reader ~= nil and sectionLimit ~= nil, "NsbcaClipCompiler requires the section reader and limit")

  local bounds = keyBounds(res)
  bounds.sectionLimit = sectionLimit
  local needs = rotTableNeeds(reader, res.targets, bounds, sectionLimit)

  local rotData, pivotData = {}, {}
  if needs.pivot then
    for i = 0, needs.pivot do
      local at = res.record + res.ofsRotData + i * 6
      reader:assertRange(at, 6, "anm-rot-pivot")
      rotData[i + 1] = {
        control = reader:u16le(at),
        a = s16(reader:u16le(at + 2)),
        b = s16(reader:u16le(at + 4)),
      }
    end
  end
  if needs.compressed then
    for i = 0, needs.compressed do
      local at = res.record + res.ofsPivotData + i * 10
      reader:assertRange(at, 10, "anm-rot-compressed")
      local e = {}
      for k = 1, 5 do
        e[k] = s16(reader:u16le(at + (k - 1) * 2))
      end
      pivotData[i + 1] = e
    end
  end

  local targets = {}
  for _, target in ipairs(res.targets) do
    local channels = target.channels
    local function copy(name, chan, isRot)
      return copyChannel(chan, reader, bounds, isRot, res.numFrame, {
        clip = clipId or "nsbca",
        target = target.nodeIndex,
        channel = name,
      })
    end
    local compiledChannels = {
      trans = {
        x = copy("trans.x", channels.trans.x, false),
        y = copy("trans.y", channels.trans.y, false),
        z = copy("trans.z", channels.trans.z, false),
      },
      rot = copy("rot", channels.rot, true),
      scale = {
        x = copy("scale.x", channels.scale.x, false),
        y = copy("scale.y", channels.scale.y, false),
        z = copy("scale.z", channels.scale.z, false),
      },
    }
    targets[#targets + 1] = {
      nodeIndex = target.nodeIndex,
      channels = compiledChannels,
    }
  end

  return {
    anmFlags = res.anmFlags,
    rotData = rotData,
    pivotData = pivotData,
    targets = targets,
  }
end

-- Build the full clip record from a decoded NSBCA resource.
--   opts.name            the Nitro dictionary entry name
--   opts.id              unique clip id (e.g. "a106-12")
--   opts.semanticNames   semantic roles (e.g. { "door.open" })
--   opts.source          provenance block (archive, memberId, sha1)
function NsbcaClipCompiler.compile(res, reader, sectionLimit, opts)
  opts = opts or {}
  local payload = NsbcaClipCompiler.compilePayload(res, reader, sectionLimit, opts.id)
  local tracks = {}
  for i, target in ipairs(payload.targets) do
    tracks[#tracks + 1] = { target = target.nodeIndex, targetIndex = i - 1 }
  end
  return {
    id = opts.id or "nsbca",
    name = opts.name or "nsbca",
    category = AnimationClip.CATEGORIES.joint,
    kind = AnimationClip.KINDS.TRS,
    frameCount = res.numFrame,
    tracks = tracks,
    semanticNames = opts.semanticNames or {},
    source = opts.source or { type = "nitro", format = "NSBCA" },
    compiled = payload,
  }
end

return NsbcaClipCompiler
