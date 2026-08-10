-- NSBMA (MAT0) material-color animation decoder and sampler.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_nsbma.s (pinned commit 038cccaed,
-- 2025-12-24), layout cross-verified against real HGSS field members.
-- Record layout (record-relative):
--
--   +0x00 u32 size      +0x04 u16 numFrame
--   +0x09 u8  numTargets (high byte of the u16 at +0x08; the ObjInit count)
--   +0x0E u16 ofsTargets
--   stride table at record + 8 + ofsTargets: u16 stride, u16 ofsNameTable
--   per-target records at record + 0x0C + ofsTargets + stride * i, five
--   u32 channel flags: diffuse, ambient, specular, emission, alpha
--   target names at stride table + ofsNameTable, 16 bytes each
--
-- A channel flag is self-contained: bits 0-15 hold the key-array offset,
-- bits 16-28 the limit (or the constant value when bit 29 is set), bit 29
-- marks a constant (value = (flag >> 16) & 0xFFFF), bits 30-31 the rate.
-- Color keys are u16 RGB555 values; alpha keys are u8 (0-31). Odd frames
-- average neighboring keys channel-wise (the 0x7C1F/0x3E0 masks keep the
-- R/G/B channels from bleeding into each other); quarter-rate odd frames
-- weight 3:1 toward the nearer key. Frames past the limit read the last
-- key.
--
-- The calc packs the results into the DS registers: diffuse + ambient into
-- diffAmb (low/high 16), specular + emission into specEmi, alpha into
-- polyAttr bits 16-20 -- this decoder returns the components and leaves the
-- register packing (which must preserve the material's 0x8000 vertex-color
-- bit and the other polyAttr fields) to the runtime. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local NitroFile = require("romdump.src.digest.nitro.NitroFile")
local NitroDict = require("romdump.src.digest.nitro.NitroDict")

local Nsbma = {}

local NAME_SIZE = 16
local BIT_CONST = 0x20000000
local BIT_HALF = 0x40000000

local function bitSet(value, bit)
  return math.floor(value / bit) % 2 == 1
end

local function asr(value, bits)
  return math.floor(value / 2 ^ bits)
end

-- 15-bit RGB555 channel masks, as the asm's 0x7C1F (B+R) and 0x3E0 (G)
-- constants: B = bits 0-4, G = bits 5-9, R = bits 10-14 (bit 15 excluded).
local function brOf(v)
  return v % 32 + (v % 32768 - v % 1024)
end
local function gOf(v)
  return v % 1024 - v % 32
end

-- Average two RGB555 colors per channel, as the asm does (no carry between
-- channels, top bit not preserved).
local function avgColor(a, b)
  return asr(gOf(a) + gOf(b), 1) + asr(brOf(a) + brOf(b), 1)
end

local function weightedColor(a, b)
  return asr(3 * gOf(a) + gOf(b), 2) + asr(3 * brOf(a) + brOf(b), 2)
end

local function decodeChannel(flag, isAlpha)
  return {
    source = bitSet(flag, BIT_CONST) and "constant" or "curve",
    value = math.floor(flag / 65536) % 65536,
    limit = math.floor(flag / 65536) % 8192,
    rate = bitSet(flag, BIT_HALF) and 2 or bitSet(flag, 0x80000000) and 4 or 1,
    ofs = flag % 65536,
    isAlpha = isAlpha,
  }
end

-- The shared odd-frame index logic; `read` returns one key value. Alpha
-- channels read u8 keys without the color-channel averaging.
local function sampleKeys(r, res, chan, frame)
  local isAlpha = chan.isAlpha
  local function single(index)
    local at = res.record + chan.ofs + index * (isAlpha and 1 or 2)
    r:assertRange(at, isAlpha and 1 or 2, "nsbma-key")
    if isAlpha then
      return r:u8(at)
    end
    return r:u16le(at)
  end
  local function pair(index)
    local a = single(index)
    local b = single(index + 1)
    return isAlpha and asr(a + b, 1) or avgColor(a, b)
  end
  local function weighted(index, index2)
    local a = single(index)
    local b = single(index2)
    return isAlpha and asr(3 * a + b, 2) or weightedColor(a, b)
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
      if frame % 4 == 1 then
        return weighted(math.floor(frame / 4), math.floor(frame / 4) + 1)
      end
      return weighted(math.floor(frame / 4) + 1, math.floor(frame / 4))
    end
    return single(math.floor(frame / 4))
  end
  return single(frame)
end

-- Decode the MAT0 record at `record` (absolute within the section reader).
function Nsbma.decodeRecord(r, record, context)
  r:assertRange(record, 0x20, "nsbma-record-header")
  local numFrame = r:u16le(record + 0x04)
  local ofsTargets = r:u16le(record + 0x0E)
  -- The target count is the byte ObjInitNsBma reads (record + 0x09).
  local numTargets = r:u8(record + 0x09)

  local tableAt = record + 8 + ofsTargets
  r:assertRange(tableAt, 4, "nsbma-target-table")
  local stride = r:u16le(tableAt)
  local ofsNameTable = r:u16le(tableAt + 2)

  local names = { "diffuse", "ambient", "specular", "emission", "alpha" }
  local targets = {}
  for i = 0, numTargets - 1 do
    local at = record + 0x0C + ofsTargets + stride * i
    r:assertRange(at, 20, "nsbma-target-record")
    local channels = {}
    for c = 0, 4 do
      channels[names[c + 1]] = decodeChannel(r:u32le(at + c * 4), c == 4)
    end
    local name = r:ascii(tableAt + ofsNameTable + i * NAME_SIZE, NAME_SIZE, true)
    targets[#targets + 1] = { index = i, name = name, channels = channels }
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

-- Sample one target at `frameFx` (the calc uses the integer frame). Returns
-- { diffuse, ambient, specular, emission, alpha } as raw values (15-bit
-- colors, 0-31 alpha) -- constants as stored, sampled channels from their
-- keys. The runtime packs these into the DS material registers.
function Nsbma.sample(r, res, targetIndex, frameFx)
  local target = assert(res.targets[targetIndex + 1], "target index " .. tostring(targetIndex) .. " out of range")
  local frame = math.floor(frameFx / 4096)
  if frame >= res.numFrame then
    frame = res.numFrame - 1
  end
  if frame < 0 then
    frame = 0
  end

  local out = {}
  for name, chan in pairs(target.channels) do
    if chan.source == "constant" then
      out[name] = chan.value
    else
      out[name] = sampleKeys(r, res, chan, frame)
    end
  end
  return out
end

local function _decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BMA0", context)
  if not file then
    error(err)
  end
  local section = NitroFile.section(file, "MAT0")
  if not section then
    error(Errors.new("NSBMA_NO_MAT0", "BMA0 file has no MAT0 section", { source = context }))
  end
  local r = BinaryReader.new(section.bytes, "mat0")
  local dict = assert(NitroDict.decode(section.bytes, 8, context))
  local animations = {}
  for _, entry in ipairs(dict.entries) do
    local record = BinaryReader.new(entry.data, "nsbma-record"):u32le(0)
    animations[#animations + 1] = {
      name = entry.name,
      recordOffset = record,
      resource = Nsbma.decodeRecord(r, record, context),
    }
  end
  return { format = "NSBMA", section = section.magic, bytes = section.bytes, animations = animations, source = context }
end

function Nsbma.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Nsbma
