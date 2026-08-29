-- CompiledNsbtaSampler: the runtime sampler over a compiled NSBTA clip
-- payload (NsbtaClipCompiler, digest side). The engine never touches NSBTA
-- bytes; this module reproduces the Nitro texture-SRT sampling math over
-- the compiled channels and must stay bit-identical to Nsbta.sample -- the
-- cross-check tests sample every fixture through both paths and require
-- equal results.
--
-- Input: a clip whose `compiled` payload is
--
--   { targets = { { index, name, channels = {
--       transS, transT, rot, scaleS, scaleT } } } }
--
-- where each channel is
--   { source = "constant", value = u32 }     -- the ofs field IS the value
--   { source = "curve", rate = 1|2|4, limit, storage = "fx16"|"fx32",
--     keys = { ... } }                       -- raw words as decoded: fx16
--     sign-extended, fx32 raw u32, rotation keys always packed u32
--     (sin low half, cos high half, fx16; 0x10000000 = identity)
--
-- The source vocabulary is {constant, curve}: the compiler rejects absent
-- channels (corpus: no real NSBTA member has one), so the sampler has no
-- identity fallback -- identity components are authored as explicit
-- constants (scale 0x1000, rotation identity word, translation 0). The
-- artifact gate (ModelAsset.validate) rejects any other source before the
-- runtime, so a bad channel here is a program invariant, not data.
--
-- The result matches GetTexSRTAnm_ (pokediamond NNS_G3D_nsbta.s): the
-- "one" flags select the texture-matrix variant, and a component flagged
-- "one" carries no value:
--   transOne  = transS == 0 and transT == 0
--   rotOne    = rotation identity
--   scaleOne  = scaleS == 0x1000 and scaleT == 0x1000
-- Pure domain module.

local AnimationClip = require("libs.assets.src.AnimationClip")

local CompiledNsbtaSampler = {}

local ROT_IDENTITY = 0x10000000
local FRAME_UNIT = AnimationClip.FRAME_UNIT

local function s16(value)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

local function asr(value, bits)
  return math.floor(value / 2 ^ bits)
end

-- ---- vector channels (transS/transT/scaleS/scaleT) ----

local function sampleVectorSingle(keys, index)
  return keys[index + 1]
end

local function sampleVectorPair(keys, index)
  return asr(keys[index + 1] + keys[index + 2], 1)
end

local function sampleVector(chan, frame)
  local keys = chan.keys
  if chan.rate == 2 then
    if frame % 2 == 1 then
      return sampleVectorPair(keys, math.floor(frame / 2))
    end
    return sampleVectorSingle(keys, math.floor(frame / 2))
  elseif chan.rate == 4 then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        return sampleVectorPair(keys, math.floor(frame / 4))
      end
      local a, b
      if frame % 4 == 1 then
        a, b = math.floor(frame / 4), math.floor(frame / 4) + 1
      else
        a, b = math.floor(frame / 4) + 1, math.floor(frame / 4)
      end
      return asr(3 * sampleVectorSingle(keys, a) + sampleVectorSingle(keys, b), 2)
    end
    return sampleVectorSingle(keys, math.floor(frame / 4))
  end
  return sampleVectorSingle(keys, frame)
end

-- ---- rotation channel ----

local function unpackRot(word)
  if word == ROT_IDENTITY then
    return nil
  end
  return { sin = s16(word % 65536), cos = s16(math.floor(word / 65536) % 65536) }
end

local function rotationSingleWord(keys, index)
  return keys[index + 1]
end

local function rotationHalf(word)
  return s16(word % 65536)
end

local function rotationHighHalf(word)
  return s16(math.floor(word / 65536) % 65536)
end

local function averageRotation(keys, index)
  local a = rotationSingleWord(keys, index)
  local b = rotationSingleWord(keys, index + 1)
  return {
    sin = asr(rotationHalf(a) + rotationHalf(b), 1),
    cos = asr(rotationHighHalf(a) + rotationHighHalf(b), 1),
  }
end

local function weightedRotation(keys, a, b)
  local wa = rotationSingleWord(keys, a)
  local wb = rotationSingleWord(keys, b)
  return {
    sin = asr(3 * rotationHalf(wa) + rotationHalf(wb), 2),
    cos = asr(3 * rotationHighHalf(wa) + rotationHighHalf(wb), 2),
  }
end

local function sampleRot(chan, frame)
  local keys = chan.keys
  if chan.rate == 2 then
    if frame % 2 == 1 then
      return averageRotation(keys, math.floor(frame / 2))
    end
    return unpackRot(rotationSingleWord(keys, math.floor(frame / 2)))
  elseif chan.rate == 4 then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        return averageRotation(keys, math.floor(frame / 4))
      end
      if frame % 4 == 1 then
        return weightedRotation(keys, math.floor(frame / 4), math.floor(frame / 4) + 1)
      end
      return weightedRotation(keys, math.floor(frame / 4) + 1, math.floor(frame / 4))
    end
    return unpackRot(rotationSingleWord(keys, math.floor(frame / 4)))
  end
  return unpackRot(rotationSingleWord(keys, frame))
end

local function channelSource(clip, targetIndex, chan, name)
  local source = chan and chan.source
  assert(
    source == "constant" or source == "curve",
    "compiled NSBTA clip "
      .. tostring(clip.id)
      .. " target "
      .. tostring(targetIndex)
      .. " channel "
      .. name
      .. " source is neither constant nor curve"
  )
  return source
end

local function sampleVectorValue(clip, targetIndex, chan, name, frame)
  if channelSource(clip, targetIndex, chan, name) == "constant" then
    return chan.value
  end
  return sampleVector(chan, frame)
end

-- Sample one target of a compiled NSBTA clip at `frameFx` (fixed-point;
-- the calc uses the integer frame, so the fractional part is ignored and
-- the frame is clamped into [0, numFrame - 1] like the decoder). The gate
-- enforces limit == frameCount for every curve, so frame > limit is
-- unreachable and the rate-2/rate-4 tails the raw decoder keeps for
-- out-of-range frames do not exist here. Returns
-- the texture-SRT state consumed by the texture-matrix conventions:
--   transS/transT/scaleS/scaleT   raw fx values (meaningful only when the
--                                 matching "one" flag is clear)
--   rot                          { sin, cos } or nil when identity
--   transOne/rotOne/scaleOne     the GetTexSRTAnm_ "one" flag bits
function CompiledNsbtaSampler.sample(clip, targetIndex, frameFx)
  assert(type(clip) == "table" and clip.compiled ~= nil, "CompiledNsbtaSampler requires a clip with a compiled payload")
  local target = assert(
    clip.compiled.targets[targetIndex + 1],
    "target index " .. tostring(targetIndex) .. " out of range for clip " .. clip.id
  )
  local frame = math.floor(frameFx / FRAME_UNIT)
  if frame >= clip.frameCount then
    frame = clip.frameCount - 1
  end
  if frame < 0 then
    frame = 0
  end

  local ch = target.channels
  local result = {
    transS = nil,
    transT = nil,
    rot = nil,
    scaleS = nil,
    scaleT = nil,
    transOne = false,
    rotOne = false,
    scaleOne = false,
  }

  result.transS = sampleVectorValue(clip, targetIndex, ch.transS, "transS", frame)
  result.transT = sampleVectorValue(clip, targetIndex, ch.transT, "transT", frame)

  local rot = ch.rot
  if channelSource(clip, targetIndex, rot, "rot") == "constant" then
    result.rot = unpackRot(rot.value)
  else
    result.rot = sampleRot(rot, frame)
  end
  if result.rot == nil then
    result.rotOne = true
  end

  result.scaleS = sampleVectorValue(clip, targetIndex, ch.scaleS, "scaleS", frame)
  result.scaleT = sampleVectorValue(clip, targetIndex, ch.scaleT, "scaleT", frame)
  if result.scaleS == 0x1000 and result.scaleT == 0x1000 then
    result.scaleOne = true
  end

  if result.transS == 0 and result.transT == 0 then
    result.transOne = true
  end
  return result
end

return CompiledNsbtaSampler
