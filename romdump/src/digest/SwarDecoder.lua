-- Strict SWAR (wave archive) decoder: the sample offset table at SWAR+0x38
-- and the sample blocks (wave type, loop, rate, length, and PCM8/PCM16/
-- IMA-ADPCM data) documented by GBATEK's "DS Sound Files - SWAR". The
-- ADPCM step table is the classic IMA 89-entry table. decodeSample owns the
-- PCM8/PCM16/ADPCM sample decoding the offline effect renderer consumes.
-- Pure module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local SwarDecoder = {}

-- IMA-style ADPCM step table (the NDS player's table; GBATEK "SWAV Sample
-- Block" notes the ADPCM variant uses this scheme).
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

local STEP_INDEX_TABLE = {
  -1,
  -1,
  -1,
  -1,
  2,
  4,
  6,
  8,
  -1,
  -1,
  -1,
  -1,
  2,
  4,
  6,
  8,
}

local function decodeAdpcm(data)
  -- Sample data starts with an s32 initial predictor, then 4-bit nibbles.
  local predictor = data:byte(1) + data:byte(2) * 256 + data:byte(3) * 65536 + data:byte(4) * 16777216
  if predictor >= 0x80000000 then
    predictor = predictor - 0x100000000
  end
  local stepIndex = data:byte(5)
  local samples = {}
  local n = 0
  for i = 6, #data do
    local byte = data:byte(i)
    for _, nibble in ipairs({ byte % 16, math.floor(byte / 16) }) do
      local step = STEP_TABLE[math.min(stepIndex + 1, #STEP_TABLE)]
      local diff = math.floor(step / 8)
      if nibble % 2 == 1 then
        diff = diff + math.floor(step / 4)
      end
      if nibble % 4 == 2 or nibble % 4 == 3 then
        diff = diff + math.floor(step / 2)
      end
      if nibble % 8 == 4 or nibble % 8 == 5 or nibble % 8 == 6 or nibble % 8 == 7 then
        diff = diff + step
      end
      if nibble >= 8 then
        predictor = predictor - diff
      else
        predictor = predictor + diff
      end
      if predictor < -32768 then
        predictor = -32768
      elseif predictor > 32767 then
        predictor = 32767
      end
      n = n + 1
      samples[n] = predictor
      stepIndex = stepIndex + STEP_INDEX_TABLE[nibble + 1]
      if stepIndex < 0 then
        stepIndex = 0
      elseif stepIndex >= #STEP_TABLE then
        stepIndex = #STEP_TABLE - 1
      end
    end
  end
  return samples
end

local function _decodeSamples(sample)
  if sample.waveType == 0 then
    local out = {}
    for i = 1, #sample.data do
      out[#out + 1] = (string.byte(sample.data, i) - 128) * 256
    end
    return out
  elseif sample.waveType == 1 then
    local out = {}
    for i = 1, math.floor(#sample.data / 2) do
      local v = string.byte(sample.data, i * 2 - 1) + string.byte(sample.data, i * 2) * 256
      if v >= 32768 then
        v = v - 65536
      end
      out[#out + 1] = v
    end
    return out
  elseif sample.waveType == 2 then
    return decodeAdpcm(sample.data)
  end
  Errors.raise("SND_SAMPLE_FORMAT_UNSUPPORTED", "sample wave type " .. sample.waveType .. " is unsupported", {
    waveType = sample.waveType,
  })
end

---@param sample { waveType: integer, data: string }
---@return integer[]?
---@return Errors.Error?
function SwarDecoder.decodeSample(sample)
  assert(sample and type(sample.data) == "string", "SwarDecoder.decodeSample requires a sample")
  local ok, result = pcall(_decodeSamples, sample)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

local function _decode(data, label)
  local reader = BinaryReader.new(data, label or "swar")
  if reader:length() < 0x40 or reader:ascii(0, 4) ~= "SWAR" then
    Errors.raise("SWAR_MAGIC_INVALID", "missing SWAR header", { size = reader:length() })
  end
  local count = reader:u32le(0x38)
  if count == 0 or 0x3C + count * 4 > reader:length() then
    Errors.raise("SWAR_SAMPLE_TABLE_INVALID", "sample offset table exceeds the archive", {
      count = count,
      size = reader:length(),
    })
  end
  local samples = {}
  for i = 0, count - 1 do
    local offset = reader:u32le(0x3C + i * 4)
    if offset + 0xC > reader:length() then
      Errors.raise("SWAR_SAMPLE_INVALID", "sample " .. i .. " header runs past the archive", { offset = offset })
    end
    local waveType = reader:u8(offset)
    local loop = reader:u8(offset + 1)
    local sampleRate = reader:u16le(offset + 2)
    local loopOffset = reader:u16le(offset + 6)
    local lengthUnits = reader:u32le(offset + 8)
    local dataSize = math.floor(lengthUnits * 4)
    local data = reader:bytes(offset + 12, math.min(dataSize, reader:length() - offset - 12))
    samples[i] = {
      waveType = waveType,
      loop = loop ~= 0,
      sampleRate = sampleRate,
      loopOffset = loopOffset,
      lengthUnits = lengthUnits,
      data = data,
    }
  end
  return { samples = samples }
end

---@param data string
---@param opts? { label?: string }
---@return { samples: table[] }?
---@return Errors.Error?
function SwarDecoder.decode(data, opts)
  assert(type(data) == "string", "SwarDecoder.decode requires a string")
  opts = opts or {}
  local ok, result = pcall(_decode, data, opts.label)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return SwarDecoder
