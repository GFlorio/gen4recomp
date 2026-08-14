-- Test-only fixture: bounded instrument walk of SBNK payloads for the
-- audio inventory. Layout per the NitroSDK bank structures
-- (bank.h / snd_bank.c): u32 instrument count at 0x38, u32 packed entries at
-- 0x3C where the low byte is the record type and the upper 24 bits the record
-- offset from the bank start; direct records (types 1 PCM, 2 PSG, 3 noise)
-- point at a 10-byte SNDInstParam with the wave-archive slot as the u16 at
-- param+2; drum sets (0x10) are min/max plus one SNDInstData per key; key
-- splits (0x11) are eight key bytes plus SNDInstData leaves that stop at the
-- first zero key byte; PCM leaves carry the wave-archive slot as the u16 at
-- leaf+4. Every read is bounded by the file; anything else is an anomaly
-- rather than a guess.
--
-- Scan result: { instruments = { {index=, type=, swarSlot=}, ... },
--                anomalies = { {kind=, offset=}, ... } }

local SbnkScan = {}

local INST_PCM = 1
local INST_PSG = 2
local INST_NOISE = 3
local INST_DRUM_SET = 0x10
local INST_KEY_SPLIT = 0x11

local INST_DATA_SIZE = 12

local function u8(data, pos)
  return string.byte(data, pos + 1)
end

local function u16(data, pos)
  local b1, b2 = string.byte(data, pos + 1, pos + 2)
  return b1 + b2 * 256
end

local function u32(data, pos)
  local b1, b2, b3, b4 = string.byte(data, pos + 1, pos + 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

---@param data string
---@return table
function SbnkScan.scan(data)
  local instruments = {}
  local anomalies = {}
  local endPos = #data

  local function anomaly(kind, offset)
    anomalies[#anomalies + 1] = { kind = kind, offset = offset }
  end

  if data:sub(1, 4) ~= "SBNK" then
    anomaly("bad-magic", 0)
    return { instruments = instruments, anomalies = anomalies }
  end
  if endPos < 0x40 then
    anomaly("short-bank", 0)
    return { instruments = instruments, anomalies = anomalies }
  end

  local instCount = u32(data, 0x38)
  -- Direct records point at an SNDInstParam whose swav/swar pair starts at
  -- the record offset; drum-set and key-split leaves are full SNDInstData
  -- records with a leading type byte.
  local function paramSwar(recordPos)
    if recordPos + 10 > endPos then
      return nil, "record-past-end"
    end
    return u16(data, recordPos + 2)
  end

  local function leafSwar(leafPos)
    if leafPos + INST_DATA_SIZE > endPos then
      return nil, "leaf-past-end"
    end
    if u8(data, leafPos) == INST_PCM then
      return u16(data, leafPos + 4)
    end
    return nil
  end

  for index = 0, instCount - 1 do
    local entryPos = 0x3C + index * 4
    if entryPos + 4 > endPos then
      anomaly("table-past-end", entryPos)
      break
    end
    local packed = u32(data, entryPos)
    local type = packed % 256
    local offset = math.floor(packed / 256)

    if type == INST_DRUM_SET then
      if offset + 2 > endPos then
        anomaly("record-past-end", offset)
      else
        local low = u8(data, offset)
        local high = u8(data, offset + 1)
        for key = 0, high - low do
          local leafPos = offset + 2 + key * INST_DATA_SIZE
          local swarSlot, problem = leafSwar(leafPos)
          if problem then
            anomaly(problem, leafPos)
            break
          end
          instruments[#instruments + 1] = { index = index, type = u8(data, leafPos), swarSlot = swarSlot }
        end
      end
    elseif type == INST_KEY_SPLIT then
      if offset + 8 > endPos then
        anomaly("record-past-end", offset)
      else
        for key = 0, 7 do
          if u8(data, offset + key) == 0 then
            break
          end
          local leafPos = offset + 8 + key * INST_DATA_SIZE
          local swarSlot, problem = leafSwar(leafPos)
          if problem then
            anomaly(problem, leafPos)
            break
          end
          instruments[#instruments + 1] = { index = index, type = u8(data, leafPos), swarSlot = swarSlot }
        end
      end
    elseif type == INST_PCM then
      local swarSlot, problem = paramSwar(offset)
      if problem then
        anomaly(problem, offset)
      else
        instruments[#instruments + 1] = { index = index, type = type, swarSlot = swarSlot }
      end
    elseif type == INST_PSG or type == INST_NOISE or type == 0 then
      -- no wave-archive reference
    else
      anomaly("unknown-type", entryPos)
    end
  end

  return { instruments = instruments, anomalies = anomalies }
end

return SbnkScan
