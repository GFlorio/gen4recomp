-- NSBTA (SRT0) texture-SRT animation decoder and sampler.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_nsbta.s (pinned commit 038cccaed,
-- 2025-12-24), layout cross-verified against real HGSS field members.
-- Record layout (record-relative):
--
--   +0x00 u32 size      +0x04 u16 numFrame
--   +0x09 u8  numTargets (high byte of the u16 at +0x08; the ObjInit count)
--   +0x0E u16 ofsTargets
--   stride table at record + 8 + ofsTargets: u16 stride, u16 ofsNameTable
--   per-target records at record + 0x0C + ofsTargets + stride * i, five
--   (u32 flag, u32 ofs) channels in the GetTexSRTAnm_ read order:
--   scaleS, scaleT, rot, transS, transT (pokediamond NNS_G3D_nsbta.s
--   0x020BE030 reads +0x18/+0x20 as the translation pair, +0x00/+0x08 as
--   the scale pair)
--   target names at stride table + ofsNameTable, 16 bytes each
--
-- Channel flag: bits 0-15 limit (last key index in rate units), bit 28 fx16
-- storage, bit 29 constant (the ofs field IS the value), bits 30-31 rate.
-- Vector keys are one value per channel (u16 or u32 per storage); rotation
-- keys are always packed u32 (sin | cos << 16), fx16 each, with the special
-- value 0x10000000 meaning identity.
--
-- The calc passes the integer frame (frame >> 12): there is no fractional
-- interpolation. Odd frames average the two neighboring keys: half rate
-- (a + b) >> 1, quarter rate 3a + b >> 2 weighted toward the nearer key;
-- frames past the limit read the last key. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroFile = require("romdump.src.digest.nitro.NitroFile")
local NitroDict = require("romdump.src.digest.nitro.NitroDict")

local Nsbta = {}

local NAME_SIZE = 16
local BIT_CONST = 0x20000000
local BIT_FX16 = 0x10000000
local BIT_HALF = 0x40000000
local ROT_IDENTITY = 0x10000000

local function bitSet(value, bit)
  return math.floor(value / bit) % 2 == 1
end

local function asr(value, bits)
  return math.floor(value / 2 ^ bits)
end

local function s16(value)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

-- One channel: constant value or a key array (offset + storage + rate +
-- limit). `packedPair` marks the rotation channel (u32 keys of fx16 pairs).
local function decodeChannel(r, record, at, packedPair, context)
  r:assertRange(at, 8, "nsbta-channel")
  local flag = r:u32le(at)
  local ofs = r:u32le(at + 4)
  if bitSet(flag, BIT_CONST) then
    return { source = "constant", value = ofs, flagRaw = flag }
  end
  return {
    source = "curve",
    storage = bitSet(flag, BIT_FX16) and "fx16" or "fx32",
    rate = bitSet(flag, BIT_HALF) and 2 or bitSet(flag, 0x80000000) and 4 or 1,
    limit = flag % 65536,
    ofs = record + ofs,
    packedPair = packedPair,
    flagRaw = flag,
  }
end

-- Read one key: a vector channel value, or the packed sin/cos pair of the
-- rotation channel.
local function readKey(r, chan, index)
  if chan.packedPair then
    r:assertRange(chan.ofs + index * 4, 4, "nsbta-rot-key")
    local word = r:u32le(chan.ofs + index * 4)
    return { sin = s16(word % 65536), cos = s16(math.floor(word / 65536) % 65536) }
  end
  if chan.storage == "fx16" then
    r:assertRange(chan.ofs + index * 2, 2, "nsbta-key")
    local v = r:u16le(chan.ofs + index * 2)
    if v >= 32768 then
      v = v - 65536
    end
    return { value = v }
  end
  r:assertRange(chan.ofs + index * 4, 4, "nsbta-key")
  return { value = r:u32le(chan.ofs + index * 4) }
end

-- The integer-frame vector sampler shared by trans and scale channels.
-- Returns the fx value.
local function sampleVector(r, chan, frame)
  local function single(index)
    return readKey(r, chan, index).value
  end
  local function pair(index)
    local a = readKey(r, chan, index).value
    local b = readKey(r, chan, index + 1).value
    return asr(a + b, 1)
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
      return asr(3 * readKey(r, chan, a).value + readKey(r, chan, b).value, 2)
    end
    return single(math.floor(frame / 4))
  end
  return single(frame)
end

-- The rotation sampler: returns { sin, cos } or nil for identity.
local function sampleRot(r, chan, frame)
  local function singleWord(index)
    r:assertRange(chan.ofs + index * 4, 4, "nsbta-rot-key")
    return r:u32le(chan.ofs + index * 4)
  end
  local function unpack(word)
    if word == ROT_IDENTITY then
      return nil
    end
    return { sin = s16(word % 65536), cos = s16(math.floor(word / 65536) % 65536) }
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
    -- 3:1 toward the nearer key (a receives the 3x), per half.
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
        return unpack(singleWord(math.floor(chan.limit / 2) + 1))
      end
      return avgPair(math.floor(frame / 2))
    end
    return unpack(singleWord(math.floor(frame / 2)))
  elseif chan.rate == 4 then
    if frame % 4 ~= 0 then
      if frame > chan.limit then
        return unpack(singleWord(frame % 4 + math.floor(chan.limit / 4)))
      end
      if frame % 4 == 2 then
        return avgPair(math.floor(frame / 4))
      end
      if frame % 4 == 1 then
        return weightedPair(math.floor(frame / 4), math.floor(frame / 4) + 1)
      end
      return weightedPair(math.floor(frame / 4) + 1, math.floor(frame / 4))
    end
    return unpack(singleWord(math.floor(frame / 4)))
  end
  return unpack(singleWord(frame))
end

-- Decode the SRT0 record at `record` (absolute within the section reader).
function Nsbta.decodeRecord(r, record, context)
  r:assertRange(record, 0x20, "nsbta-record-header")
  local numFrame = r:u16le(record + 0x04)
  local ofsTargets = r:u16le(record + 0x0E)
  -- The target count is the byte ObjInitNsBta reads (record + 0x09); the
  -- u16 at +0x16 is unrelated metadata (verified: 2-target members read
  -- 0x0103 there while the real count is 5).
  local numTargets = r:u8(record + 0x09)

  local tableAt = record + 8 + ofsTargets
  r:assertRange(tableAt, 4, "nsbta-target-table")
  local stride = r:u16le(tableAt)
  local ofsNameTable = r:u16le(tableAt + 2)

  local targets = {}
  for i = 0, numTargets - 1 do
    local at = record + 0x0C + ofsTargets + stride * i
    r:assertRange(at, 40, "nsbta-target-record")
    -- Channel order per GetTexSRTAnm_: scale pair first, then rot, then the
    -- translation pair (the asm reads +0x18/+0x20 as the translations).
    local chans = {
      scaleS = decodeChannel(r, record, at, false, context),
      scaleT = decodeChannel(r, record, at + 8, false, context),
      rot = decodeChannel(r, record, at + 0x10, true, context),
      transS = decodeChannel(r, record, at + 0x18, false, context),
      transT = decodeChannel(r, record, at + 0x20, false, context),
    }
    local nameAt = tableAt + ofsNameTable + i * NAME_SIZE
    local name = r:ascii(nameAt, NAME_SIZE, true)
    targets[#targets + 1] = { index = i, name = name, channels = chans }
  end

  return {
    numFrame = numFrame,
    numTargets = numTargets,
    ofsTargets = ofsTargets,
    stride = stride,
    targets = targets,
    record = record,
    source = context,
  }
end

-- Sample one target at `frameFx` (fixed-point; the calc uses the integer
-- frame, so the fractional part is ignored). Returns the texture-SRT state:
--   transS/transT/scaleS/scaleT  the sampled fx values (meaningful only when
--                                 the matching "one" flag is clear)
--   rot                        { sin, cos } or nil when identity
--   transOne/rotOne/scaleOne   the GetTexSRTAnm_ "one" flag bits: transOne
--                              = both translations zero, rotOne = identity
--                              rotation, scaleOne = both scales 0x1000
---@return { transS: number|nil, transT: number|nil, scaleS: number|nil, scaleT: number|nil, rot: { sin: number, cos: number }|nil, transOne: boolean, rotOne: boolean, scaleOne: boolean }
function Nsbta.sample(r, res, targetIndex, frameFx)
  local target = assert(res.targets[targetIndex + 1], "target index " .. tostring(targetIndex) .. " out of range")
  local frame = math.floor(frameFx / 4096)
  if frame >= res.numFrame then
    frame = res.numFrame - 1
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

  local function value(chan, sampler)
    if chan.source == "constant" then
      return chan.value
    end
    return sampler(r, chan, frame)
  end

  result.transS = value(ch.transS, sampleVector)
  result.transT = value(ch.transT, sampleVector)

  local rot = ch.rot
  if rot.source == "constant" then
    if rot.value ~= ROT_IDENTITY then
      result.rot = { sin = s16(rot.value % 65536), cos = s16(math.floor(rot.value / 65536) % 65536) }
    else
      result.rotOne = true
    end
  else
    result.rot = sampleRot(r, rot, frame)
    if result.rot == nil then
      result.rotOne = true
    end
  end

  result.scaleS = value(ch.scaleS, sampleVector)
  result.scaleT = value(ch.scaleT, sampleVector)
  -- GetTexSRTAnm_ compares the pair against 0x1000 (the identity scale), not
  -- zero: a zero scale contributes nothing to the matrix cells, so both
  -- encodings render identically, but 0x1000 must select the no-scale
  -- variant to avoid a phantom shift (one real member authors exactly that).
  if result.scaleS == 0x1000 and result.scaleT == 0x1000 then
    result.scaleOne = true
  end
  if result.transS == 0 and result.transT == 0 then
    result.transOne = true
  end

  return result
end

local function _decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BTA0", context)
  if not file then
    error(err)
  end
  local section = NitroFile.section(file, "SRT0")
  if not section then
    error(Errors.new("NSBTA_NO_SRT0", "BTA0 file has no SRT0 section", { source = context }))
  end
  local r = BinaryReader.new(section.bytes, "srt0")
  local dict = assert(NitroDict.decode(section.bytes, 8, context))
  local animations = {}
  for _, entry in ipairs(dict.entries) do
    local record = BinaryReader.new(entry.data, "nsbta-record"):u32le(0)
    animations[#animations + 1] = {
      name = entry.name,
      recordOffset = record,
      resource = Nsbta.decodeRecord(r, record, context),
    }
  end
  return { format = "NSBTA", section = section.magic, bytes = section.bytes, animations = animations, source = context }
end

function Nsbta.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Nsbta
