-- Strict SBNK (sound bank) decoder: the instrument table at SBNK+0x38 with
-- four-byte records (fRecord, 16-bit data offset), and the direct (1..3),
-- range (16) and regional (17) instrument layouts documented by GBATEK's
-- "DS Sound Files - SBNK". Pure module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local SbnkDecoder = {}

local function readInstrument(reader, offset, label)
  if offset + 10 > reader:length() then
    Errors.raise("SBNK_INSTRUMENT_INVALID", label .. " instrument data runs past the bank", { offset = offset })
  end
  local swav = reader:u16le(offset)
  local swar = reader:u16le(offset + 2)
  local note = reader:u8(offset + 4)
  local attack = reader:u8(offset + 5)
  local decay = reader:u8(offset + 6)
  local sustain = reader:u8(offset + 7)
  local release = reader:u8(offset + 8)
  local pan = reader:u8(offset + 9)
  return {
    swav = swav,
    swar = swar,
    note = note,
    attack = attack,
    decay = decay,
    sustain = sustain,
    release = release,
    pan = pan,
  }
end

-- Regional entries in the shipped UI banks are 12 bytes: a 32-bit swar
-- reference, the swav byte, the note, and the six ADSR bytes (observed in
-- gs_sound_data.sdat bank 700; the GBATEK 10-byte shape applies to the
-- direct/range forms).
local function readRegionalInstrument(reader, offset, label)
  if offset + 12 > reader:length() then
    Errors.raise("SBNK_INSTRUMENT_INVALID", label .. " regional entry runs past the bank", { offset = offset })
  end
  local swar = reader:u32le(offset)
  local swav = reader:u8(offset + 4)
  local note = reader:u8(offset + 5)
  local attack = reader:u8(offset + 6)
  local decay = reader:u8(offset + 7)
  local sustain = reader:u8(offset + 8)
  local release = reader:u8(offset + 9)
  return {
    swav = swav,
    swar = swar,
    note = note,
    attack = attack,
    decay = decay,
    sustain = sustain,
    release = release,
    pan = 64,
  }
end

local function _decode(data, label)
  local reader = BinaryReader.new(data, label or "sbnk")
  if reader:length() < 0x40 or reader:ascii(0, 4) ~= "SBNK" then
    Errors.raise("SBNK_MAGIC_INVALID", "missing SBNK header", { size = reader:length() })
  end
  local count = reader:u32le(0x38)
  if count == 0 or 0x3C + count * 4 > reader:length() then
    Errors.raise("SBNK_INSTRUMENT_TABLE_INVALID", "instrument table exceeds the bank", {
      count = count,
      size = reader:length(),
    })
  end
  local instruments = {}
  for i = 0, count - 1 do
    local record = 0x3C + i * 4
    local fRecord = reader:u8(record)
    local dataOffset = reader:u16le(record + 1)
    if fRecord == 0 then
      instruments[i] = { kind = "unused" }
    elseif fRecord >= 1 and fRecord <= 3 then
      instruments[i] = { kind = "direct", entry = readInstrument(reader, dataOffset, "instrument " .. i) }
    elseif fRecord == 16 then
      if dataOffset + 4 > reader:length() then
        Errors.raise("SBNK_INSTRUMENT_INVALID", "range instrument header runs past the bank", { offset = dataOffset })
      end
      local lower = reader:u8(dataOffset)
      local upper = reader:u8(dataOffset + 1)
      local entries = {}
      local base = dataOffset + 4 + 2
      for note = lower, upper do
        if base + 10 > reader:length() then
          Errors.raise("SBNK_INSTRUMENT_INVALID", "range instrument entries run past the bank", { offset = base })
        end
        entries[note] = readInstrument(reader, base, "range entry " .. note)
        base = base + 12
      end
      instruments[i] = { kind = "range", lower = lower, upper = upper, entries = entries }
    elseif fRecord == 17 then
      if dataOffset + 10 > reader:length() then
        Errors.raise(
          "SBNK_INSTRUMENT_INVALID",
          "regional instrument header runs past the bank",
          { offset = dataOffset }
        )
      end
      local regions = {}
      local base = dataOffset + 10
      for r = 1, 8 do
        local regionEnd = reader:u8(dataOffset + r - 1)
        if regionEnd ~= 0 then
          regions[#regions + 1] =
            { regionEnd = regionEnd, entry = readRegionalInstrument(reader, base, "region " .. r) }
          base = base + 12
        end
      end
      instruments[i] = { kind = "regional", regions = regions }
    else
      Errors.raise("SBNK_INSTRUMENT_INVALID", "instrument " .. i .. " uses unsupported fRecord " .. fRecord, {
        index = i,
        fRecord = fRecord,
      })
    end
  end
  return { instruments = instruments }
end

---@param data string
---@param opts? { label?: string }
---@return { instruments: table[] }?
---@return Errors.Error?
function SbnkDecoder.decode(data, opts)
  assert(type(data) == "string", "SbnkDecoder.decode requires a string")
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

return SbnkDecoder
