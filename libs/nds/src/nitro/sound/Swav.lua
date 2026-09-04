-- Offline SWAV member decoder: the 12-byte SNDWaveParam (format u8, loop
-- flag u8, sample rate u16, timer u16, loop offset u16 in 4-byte words,
-- length u32 in 4-byte words) plus sample data, converted to signed PCM16LE
-- with engine-meaningful frame, base-timer and loop-window units. The size
-- relation memberSize == 12 + 4*(pnt+len) and the loop conversions follow
-- the DS channel registers as GBATEK documents them and melonDS implements
-- them: total words = pnt + len, so PCM8 yields 4*(pnt+len) frames and PCM16
-- 2*(pnt+len); ADPCM data starts with a 4-byte predictor/index header and
-- decodes low nibble first to 8*(pnt+len-1) frames. Loop windows are
-- {startFrame, endFrame}: [4*pnt, frames) / [2*pnt, frames) / [8*(pnt-1),
-- frames); waves without a loop flag (or with the loop at the header) get
-- the full-range window {0, frames}. Pure domain module.

local Errors = require("libs.errors.src.Errors")

local Swav = {}

Swav.FORMAT_PCM8 = 0
Swav.FORMAT_PCM16 = 1
Swav.FORMAT_ADPCM = 2

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

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

local function u8At(bytes, offset, _)
  return string.byte(bytes, offset + 1)
end

local function u16At(bytes, offset, _)
  return string.byte(bytes, offset + 1) + string.byte(bytes, offset + 2) * 256
end

local function u32At(bytes, offset, _)
  return string.byte(bytes, offset + 1)
    + string.byte(bytes, offset + 2) * 256
    + string.byte(bytes, offset + 3) * 65536
    + string.byte(bytes, offset + 4) * 16777216
end

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

-- Appends a signed 16-bit sample in little-endian order to `parts`.
local function pushSample(parts, value)
  if value < 0 then
    value = value + 0x10000
  end
  parts[#parts + 1] = string.char(value % 256, math.floor(value / 256) % 256)
end

local function decodePcm8(bytes, dataOffset, frames, source)
  local parts = {}
  for i = 0, frames - 1 do
    local byte = u8At(bytes, dataOffset + i, source)
    local sample = byte * 256
    if byte >= 128 then
      sample = sample - 65536
    end
    pushSample(parts, sample)
  end
  return table.concat(parts)
end

local function decodePcm16(bytes, dataOffset, frames, source)
  local parts = {}
  for i = 0, frames - 1 do
    local value = u16At(bytes, dataOffset + i * 2, source)
    if value >= 0x8000 then
      value = value - 0x10000
    end
    pushSample(parts, value)
  end
  return table.concat(parts)
end

-- GBATEK "IMA-ADPCM Format" with the DS rounding and clamping quirks:
-- nibbles are stored low half first, two per byte.
local function decodeAdpcm(bytes, dataOffset, frames, source)
  local predictor = u16At(bytes, dataOffset, source)
  if predictor >= 0x8000 then
    predictor = predictor - 0x10000
  end
  local index = clamp(u8At(bytes, dataOffset + 2, source), 0, 88)
  local parts = {}
  for i = 0, frames - 1 do
    local byte = u8At(bytes, dataOffset + 4 + math.floor(i / 2), source)
    local nibble = i % 2 == 0 and byte % 16 or math.floor(byte / 16)
    local step = STEP_TABLE[index + 1]
    local diff = math.floor(step / 8)
    if nibble % 2 == 1 then
      diff = diff + math.floor(step / 4)
    end
    if math.floor(nibble / 2) % 2 == 1 then
      diff = diff + math.floor(step / 2)
    end
    if math.floor(nibble / 4) % 2 == 1 then
      diff = diff + step
    end
    if math.floor(nibble / 8) % 2 == 1 then
      predictor = predictor - diff
      if predictor < -0x7FFF then
        predictor = -0x7FFF
      end
    else
      predictor = predictor + diff
      if predictor > 0x7FFF then
        predictor = 0x7FFF
      end
    end
    index = clamp(index + INDEX_TABLE[nibble % 8 + 1], 0, 88)
    pushSample(parts, predictor)
  end
  return table.concat(parts)
end

local function _decode(bytes, context)
  local source = context or "SWAV"
  local size = #bytes
  if size < 12 then
    fail("SWAV_TRUNCATED", "wave member is shorter than its parameter header", {
      source = source,
      actual = size,
    })
  end
  local format = u8At(bytes, 0, source)
  if format > Swav.FORMAT_ADPCM then
    fail("SWAV_UNSUPPORTED_FORMAT", "unsupported wave sample format", {
      source = source,
      format = format,
    })
  end
  local loopEnabled = u8At(bytes, 1, source) ~= 0
  local sampleRate = u16At(bytes, 2, source)
  local timer = u16At(bytes, 4, source)
  local pnt = u16At(bytes, 6, source)
  local len = u32At(bytes, 8, source)

  if size ~= 12 + 4 * (pnt + len) then
    fail("SWAV_SIZE_MISMATCH", "wave member size does not match its loop offset and length", {
      source = source,
      actual = size,
      expected = 12 + 4 * (pnt + len),
      loopOffset = pnt,
      length = len,
    })
  end

  local frames
  local loopStart
  if format == Swav.FORMAT_PCM8 then
    frames = 4 * (pnt + len)
    loopStart = 4 * pnt
  elseif format == Swav.FORMAT_PCM16 then
    frames = 2 * (pnt + len)
    loopStart = 2 * pnt
  else
    frames = 8 * (pnt + len) - 8
    loopStart = 8 * (pnt - 1)
  end

  local loop
  if loopEnabled and loopStart >= 0 then
    loop = { startFrame = loopStart, endFrame = frames }
  else
    loop = { startFrame = 0, endFrame = frames }
  end
  if loop.startFrame >= loop.endFrame or loop.endFrame > frames then
    fail("SWAV_LOOP_OUT_OF_RANGE", "wave loop window is invalid", {
      source = source,
      format = format,
      loopOffset = pnt,
      length = len,
      frames = frames,
      loop = loop,
    })
  end

  local pcm16le
  if format == Swav.FORMAT_PCM8 then
    pcm16le = decodePcm8(bytes, 12, frames, source)
  elseif format == Swav.FORMAT_PCM16 then
    pcm16le = decodePcm16(bytes, 12, frames, source)
  else
    pcm16le = decodeAdpcm(bytes, 12, frames, source)
  end

  return {
    format = format,
    loopEnabled = loopEnabled,
    sampleRate = sampleRate,
    -- The DS base timer drives NNS pitch calculation (SND_CalcTimer); it is
    -- preserved verbatim, never re-derived from the rate.
    baseTimer = timer,
    frames = frames,
    loop = loop,
    pcm16le = pcm16le,
  }
end

---@param bytes string
---@param context string?
---@return table<string, unknown>?|nil
---@return Errors.Error?|nil
function Swav.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return Swav
