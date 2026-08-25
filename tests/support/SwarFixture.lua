-- Test helper: assemble SWAR embedded-resource bytes with SWAV sample
-- members. Layout follows GBATEK "DS Sound Files - SWAV/SWAR" and the NNS
-- SNDWaveArc struct: a 16-byte NNS file header, a DATA block header, a u32
-- wave count at 0x38, u32 member offsets at 0x3C (absolute from the SWAR
-- start), then the members. A member is a 12-byte SNDWaveParam (format u8,
-- loop flag u8, sample rate u16, timer u16, loop offset u16 in 4-byte units,
-- length u32 in 4-byte units) followed by sample data; the size relation
-- memberSize == 12 + 4*(pnt+len) holds for every format (verified against the
-- HGSS dump for ADPCM). ADPCM data starts with a 4-byte predictor/index
-- header then low-nibble-first 4-bit samples; PCM8/PCM16 are signed.
--
-- Member builders: SwarFixture.pcm8/pcm16/adpcm(samples, opts) encode from
-- sample arrays (opts: loopFlag, pnt, len, sampleRate); the default layout is
-- one-shot (pnt 0) with the length derived from the sample count. build()
-- returns bytes, layout { memberOffsets = { [i] = offset } }.
-- Test-only fixture.

local FntWriter = require("tests.support.FntWriter")

local SwarFixture = {}

local function u8(v)
  return string.char(v % 256)
end
local u16, u32 = FntWriter.u16, FntWriter.u32

SwarFixture.FORMAT_PCM8 = 0
SwarFixture.FORMAT_PCM16 = 1
SwarFixture.FORMAT_ADPCM = 2

-- GBATEK "DS Sound Channels": the IMA-ADPCM step and index tables.
local STEP_TABLE = {
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  16,
  17,
  19,
  21,
  23,
  25,
  28,
  31,
  34,
  37,
  41,
  45,
  50,
  55,
  60,
  66,
  73,
  80,
  88,
  97,
  107,
  118,
  130,
  143,
  157,
  173,
  190,
  209,
  230,
  253,
  279,
  307,
  337,
  371,
  408,
  449,
  494,
  544,
  598,
  658,
  724,
  796,
  876,
  963,
  1060,
  1166,
  1282,
  1411,
  1552,
  1707,
  1878,
  2066,
  2272,
  2499,
  2749,
  3024,
  3327,
  3660,
  4026,
  4428,
  4871,
  5358,
  5894,
  6484,
  7132,
  7845,
  8630,
  9493,
  10442,
  11487,
  12635,
  13899,
  15289,
  16818,
  18500,
  20350,
  22385,
  24623,
  27086,
  29794,
  32767,
}
local INDEX_TABLE = { -1, -1, -1, -1, 2, 4, 6, 8 }

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function s16le(value)
  if value < 0 then
    value = value + 0x10000
  end
  return u16(value)
end

-- Greedy IMA encoder over the DS tables: nibble stream (low nibble first),
-- with the initial predictor and index (sample 1, index 0) in the header.
local function adpcmEncode(samples)
  assert(#samples % 8 == 0, "ADPCM fixture samples must be a multiple of 8")
  local initialPredictor = samples[1]
  local initialIndex = 0
  local predictor = initialPredictor
  local index = initialIndex
  local nibbles = {}
  for i = 2, #samples do
    local diff = samples[i] - predictor
    local sign = 0
    if diff < 0 then
      sign = 8
      diff = -diff
    end
    local step = STEP_TABLE[index + 1]
    local mag = clamp(math.floor((diff * 8 + step / 2) / step), 0, 7)
    local decodedDiff = math.floor(step / 8)
    if mag % 2 == 1 then
      decodedDiff = decodedDiff + math.floor(step / 4)
    end
    if math.floor(mag / 2) % 2 == 1 then
      decodedDiff = decodedDiff + math.floor(step / 2)
    end
    if mag >= 4 then
      decodedDiff = decodedDiff + step
    end
    if sign ~= 0 then
      predictor = predictor - decodedDiff
      if predictor < -0x7FFF then
        predictor = -0x7FFF
      end
    else
      predictor = predictor + decodedDiff
      if predictor > 0x7FFF then
        predictor = 0x7FFF
      end
    end
    index = clamp(index + INDEX_TABLE[mag + 1], 0, 88)
    nibbles[#nibbles + 1] = mag + sign
  end
  if #nibbles % 2 == 1 then
    nibbles[#nibbles + 1] = 0
  end
  local bytes = {}
  for i = 1, #nibbles, 2 do
    bytes[#bytes + 1] = u8(nibbles[i] + nibbles[i + 1] * 16)
  end
  return initialPredictor, initialIndex, table.concat(bytes)
end

-- `timer` overrides the timer derived from the sample rate, so tests can pin
-- the exact base timer a member carries.
local function member(format, loopFlag, sampleRate, pnt, len, data, timer)
  local param = u8(format)
    .. u8(loopFlag)
    .. u16(sampleRate)
    .. u16(timer or math.floor(16756991 / sampleRate))
    .. u16(pnt)
    .. u32(len)
  return param .. data
end

-- PCM8 member: samples -128..127, padded to a multiple of 4.
---@param samples integer[]
---@param opts table?
---@return string
function SwarFixture.pcm8(samples, opts)
  opts = opts or {}
  while #samples % 4 ~= 0 do
    samples[#samples + 1] = 0
  end
  local pnt = opts.pnt or 0
  local len = opts.len or math.floor(#samples / 4)
  local parts = {}
  for _, s in ipairs(samples) do
    parts[#parts + 1] = u8(s % 256)
  end
  return member(
    SwarFixture.FORMAT_PCM8,
    opts.loopFlag or 0,
    opts.sampleRate or 22050,
    pnt,
    len,
    table.concat(parts),
    opts.timer
  )
end

-- PCM16 member: samples -32768..32767, padded to a multiple of 2.
---@param samples integer[]
---@param opts table?
---@return string
function SwarFixture.pcm16(samples, opts)
  opts = opts or {}
  while #samples % 2 ~= 0 do
    samples[#samples + 1] = 0
  end
  local pnt = opts.pnt or 0
  local len = opts.len or math.floor(#samples / 2)
  local parts = {}
  for _, s in ipairs(samples) do
    parts[#parts + 1] = s16le(s)
  end
  return member(
    SwarFixture.FORMAT_PCM16,
    opts.loopFlag or 0,
    opts.sampleRate or 22050,
    pnt,
    len,
    table.concat(parts),
    opts.timer
  )
end

-- ADPCM member encoded from samples (multiple of 8). The default one-shot
-- layout is pnt 0 with len = data words + 1 (the header word is counted in
-- the length for one-shot waves, exactly as the HGSS dump lays them out).
---@param samples integer[]
---@param opts table?
---@return string
function SwarFixture.adpcm(samples, opts)
  opts = opts or {}
  local predictor, index, nibbles = adpcmEncode(samples)
  local dataWords = math.floor(#nibbles / 4)
  local pnt = opts.pnt
  local len
  if pnt == nil then
    pnt = 0
    len = dataWords + 1
  else
    len = opts.len or (dataWords - pnt + 1)
  end
  local header = u16(predictor % 0x10000) .. u8(index) .. u8(0)
  return member(
    SwarFixture.FORMAT_ADPCM,
    opts.loopFlag or 0,
    opts.sampleRate or 22050,
    pnt,
    len,
    header .. nibbles,
    opts.timer
  )
end

-- ADPCM member from an explicit predictor/index and raw nibble bytes, for
-- exact decode expectations. len defaults to words of the nibble data + 1.
---@param predictor integer
---@param index integer
---@param nibbles string
---@param opts table?
---@return string
function SwarFixture.adpcmRaw(predictor, index, nibbles, opts)
  opts = opts or {}
  local dataWords = math.floor(#nibbles / 4)
  local pnt = opts.pnt or 0
  local len = opts.len or dataWords + 1
  local header = u16(predictor % 0x10000) .. u8(index) .. u8(0)
  return member(
    SwarFixture.FORMAT_ADPCM,
    opts.loopFlag or 0,
    opts.sampleRate or 22050,
    pnt,
    len,
    header .. nibbles,
    opts.timer
  )
end

-- Builds the full embedded SWAR file bytes with the given members.
---@param members string[]
---@return string
---@return table
function SwarFixture.build(members)
  local content = {}
  local offsets = {}
  local cursor = 0x3C + #members * 4
  for index, memberBytes in ipairs(members) do
    offsets[index - 1] = cursor
    content[#content + 1] = memberBytes
    cursor = cursor + #memberBytes
  end
  local parts = { u32(#members) }
  for i = 0, #members - 1 do
    parts[#parts + 1] = u32(offsets[i])
  end
  local body = string.rep("\0", 0x20) .. table.concat(parts) .. table.concat(content)
  local dataBlock = "DATA" .. u32(#body + 8) .. body
  local file = "SWAR" .. u16(0xFEFF) .. u16(0x0100) .. u32(16 + #dataBlock) .. u16(0x10) .. u16(1) .. dataBlock
  return file, { memberOffsets = offsets }
end

return SwarFixture
