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
--   { source = "absent" }                    -- no data: identity component
--   { source = "constant", value = u32 }     -- the ofs field IS the value
--   { source = "curve", rate = 1|2|4, limit, storage = "fx16"|"fx32",
--     keys = { ... } }                       -- raw words as decoded: fx16
--     sign-extended, fx32 raw u32, rotation keys always packed u32
--     (sin low half, cos high half, fx16; 0x10000000 = identity)
--
-- The result matches GetTexSRTAnm_ (pokediamond NNS_G3D_nsbta.s): the
-- "one" flags select the texture-matrix variant, and a component flagged
-- "one" carries no value:
--   transOne  = transS == 0 and transT == 0
--   rotOne    = rotation identity
--   scaleOne  = scaleS == 0x1000 and scaleT == 0x1000
-- Pure domain module.

local CompiledNsbtaSampler = {}

local ROT_IDENTITY = 0x10000000
local FRAME_UNIT = 4096

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

local function sampleVector(chan, frame)
  local keys = chan.keys
  local function single(index)
    return keys[index + 1]
  end
  local function pair(index)
    return asr(keys[index + 1] + keys[index + 2], 1)
  end
  if chan.rate == 2 then
    if frame % 2 == 1 then
      if frame > chan.limit then
        return single(math.floor(chan.limit / 2) + 1)
      end
      return pair(math.floor(frame / 2))
    end
    return single(math.floor(frame / 2))
  elseif chan.rate == 4 then
    if frame % 4 ~= 0 then
      if frame > chan.limit then
        return single(frame % 4 + math.floor(chan.limit / 4))
      end
      if frame % 4 == 2 then
        return pair(math.floor(frame / 4))
      end
      local a, b
      if frame % 4 == 1 then
        a, b = math.floor(frame / 4), math.floor(frame / 4) + 1
      else
        a, b = math.floor(frame / 4) + 1, math.floor(frame / 4)
      end
      return asr(3 * keys[a + 1] + keys[b + 1], 2)
    end
    return single(math.floor(frame / 4))
  end
  return single(frame)
end

-- ---- rotation channel ----

local function unpackRot(word)
  if word == ROT_IDENTITY then
    return nil
  end
  return { sin = s16(word % 65536), cos = s16(math.floor(word / 65536) % 65536) }
end

local function sampleRot(chan, frame)
  local keys = chan.keys
  local function singleWord(index)
    return keys[index + 1]
  end
  local function half(word)
    return s16(word % 65536)
  end
  local function highHalf(word)
    return s16(math.floor(word / 65536) % 65536)
  end
  local function avgPair(index)
    local a = singleWord(index)
    local b = singleWord(index + 1)
    return {
      sin = asr(half(a) + half(b), 1),
      cos = asr(highHalf(a) + highHalf(b), 1),
    }
  end
  local function weightedPair(a, b)
    local wa = singleWord(a)
    local wb = singleWord(b)
    return {
      sin = asr(3 * half(wa) + half(wb), 2),
      cos = asr(3 * highHalf(wa) + highHalf(wb), 2),
    }
  end
  if chan.rate == 2 then
    if frame % 2 == 1 then
      if frame > chan.limit then
        return unpackRot(singleWord(math.floor(chan.limit / 2) + 1))
      end
      return avgPair(math.floor(frame / 2))
    end
    return unpackRot(singleWord(math.floor(frame / 2)))
  elseif chan.rate == 4 then
    if frame % 4 ~= 0 then
      if frame > chan.limit then
        return unpackRot(singleWord(frame % 4 + math.floor(chan.limit / 4)))
      end
      if frame % 4 == 2 then
        return avgPair(math.floor(frame / 4))
      end
      if frame % 4 == 1 then
        return weightedPair(math.floor(frame / 4), math.floor(frame / 4) + 1)
      end
      return weightedPair(math.floor(frame / 4) + 1, math.floor(frame / 4))
    end
    return unpackRot(singleWord(math.floor(frame / 4)))
  end
  return unpackRot(singleWord(frame))
end

-- Sample one target of a compiled NSBTA clip at `frameFx` (fixed-point;
-- the calc uses the integer frame, so the fractional part is ignored and
-- the frame is clamped into [0, numFrame - 1] like the decoder). Returns
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

  -- Absent channels are identity components: zero translations, identity
  -- scales (0x1000) -- the authored values GetTexSRTAnm_ would compare for
  -- its "one" flags.
  local function transValue(chan)
    if chan.source == "constant" then
      return chan.value
    end
    if chan.source == "curve" then
      return sampleVector(chan, frame)
    end
    return 0
  end
  local function scaleValue(chan)
    if chan.source == "constant" then
      return chan.value
    end
    if chan.source == "curve" then
      return sampleVector(chan, frame)
    end
    return 0x1000
  end

  result.transS = transValue(ch.transS)
  result.transT = transValue(ch.transT)

  local rot = ch.rot
  if rot.source == "constant" then
    result.rot = unpackRot(rot.value)
  elseif rot.source == "curve" then
    result.rot = sampleRot(rot, frame)
  end
  if result.rot == nil then
    result.rotOne = true
  end

  result.scaleS = scaleValue(ch.scaleS)
  result.scaleT = scaleValue(ch.scaleT)
  if result.scaleS == 0x1000 and result.scaleT == 0x1000 then
    result.scaleOne = true
  end

  if result.transS == 0 and result.transT == 0 then
    result.transOne = true
  end
  return result
end

return CompiledNsbtaSampler
