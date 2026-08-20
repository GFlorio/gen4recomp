-- Bounded decoder for the NNS SBNK bank structures as the HGSS dump lays
-- them out and the NitroSDK bank code (SND_bank_shared.h, ARM7 SND_bank.c:
-- SND_ReadInstData) interprets them: a u32 instrument count at 0x38, packed
-- u32 entries at 0x3C whose low byte is the record type and upper 24 bits the
-- record offset from the bank start; direct records (types 1 PCM, 2 PSG,
-- 3 noise, 4 DIRECTPCM) are a 10-byte SNDInstParam (swav u16, wave-archive slot u16, root
-- key u8, four ADSR u8s, pan u8); drum sets (0x10) are min/max keys plus one
-- 12-byte SNDInstData leaf per key; key splits (0x11) are eight split-key
-- bytes plus leaves that stop at the first zero key. Type-0 records are
-- illegal instruments (the player fails notes on them) and are dropped;
-- type 5 DUMMY has no playable parameters; unsupported types are build
-- failures with provenance. Pure domain module.

local Errors = require("libs.errors.src.Errors")

local Sbnk = {}

Sbnk.TYPE_PCM = 1
Sbnk.TYPE_PSG = 2
Sbnk.TYPE_NOISE = 3
Sbnk.TYPE_DIRECTPCM = 4
Sbnk.TYPE_DUMMY = 5
Sbnk.TYPE_DRUM_SET = 0x10
Sbnk.TYPE_KEY_SPLIT = 0x11

local PARAM_SIZE = 10
local LEAF_SIZE = 12
local ENTRY_TABLE_OFFSET = 0x3C

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

local function u8At(bytes, offset, source)
  return string.byte(bytes, offset + 1)
end

local function u16At(bytes, offset, source)
  return string.byte(bytes, offset + 1) + string.byte(bytes, offset + 2) * 256
end

local function u32At(bytes, offset, source)
  return string.byte(bytes, offset + 1)
    + string.byte(bytes, offset + 2) * 256
    + string.byte(bytes, offset + 3) * 65536
    + string.byte(bytes, offset + 4) * 16777216
end

-- The 10-byte SNDInstParam starting at `offset`.
local function readParam(bytes, offset, size, source)
  if offset + PARAM_SIZE > size then
    fail("SBNK_TRUNCATED", "instrument parameter extends past the end of the bank", {
      source = source,
      offset = offset,
    })
  end
  return {
    swav = u16At(bytes, offset, source),
    swarSlot = u16At(bytes, offset + 2, source),
    rootKey = u8At(bytes, offset + 4, source),
    attack = u8At(bytes, offset + 5, source),
    decay = u8At(bytes, offset + 6, source),
    sustain = u8At(bytes, offset + 7, source),
    release = u8At(bytes, offset + 8, source),
    pan = u8At(bytes, offset + 9, source),
  }
end

-- The 12-byte SNDInstData leaf starting at `offset`.
local function readLeaf(bytes, offset, size, source)
  if offset + LEAF_SIZE > size then
    fail("SBNK_TRUNCATED", "instrument leaf extends past the end of the bank", {
      source = source,
      offset = offset,
    })
  end
  local recordType = u8At(bytes, offset, source)
  if
    recordType ~= Sbnk.TYPE_PCM
    and recordType ~= Sbnk.TYPE_PSG
    and recordType ~= Sbnk.TYPE_NOISE
    and recordType ~= Sbnk.TYPE_DIRECTPCM
    and recordType ~= Sbnk.TYPE_DUMMY
  then
    fail("SBNK_UNSUPPORTED_INSTRUMENT", "unsupported instrument leaf type", {
      source = source,
      sourceOffset = offset,
      type = recordType,
    })
  end
  if recordType == Sbnk.TYPE_DUMMY then
    return { type = recordType }
  end
  return { type = recordType, param = readParam(bytes, offset + 2, size, source) }
end

local function _decode(bytes, context)
  local source = context or "SBNK"
  local size = #bytes
  if size < ENTRY_TABLE_OFFSET + 4 then
    fail("SBNK_TRUNCATED", "bank is shorter than its instrument table header", {
      source = source,
      actual = size,
    })
  end
  local instCount = u32At(bytes, 0x38, source)
  if ENTRY_TABLE_OFFSET + instCount * 4 > size then
    fail("SBNK_TRUNCATED", "instrument table extends past the end of the bank", {
      source = source,
      instCount = instCount,
    })
  end

  local instruments = {}
  for program = 0, instCount - 1 do
    local packed = u32At(bytes, ENTRY_TABLE_OFFSET + program * 4, source)
    local recordType = packed % 256
    local offset = math.floor(packed / 256)
    if recordType == 0 then
      -- illegal record: notes on this program are silent
    elseif
      recordType == Sbnk.TYPE_PCM
      or recordType == Sbnk.TYPE_PSG
      or recordType == Sbnk.TYPE_NOISE
      or recordType == Sbnk.TYPE_DIRECTPCM
    then
      instruments[program] = {
        type = recordType,
        param = readParam(bytes, offset, size, source),
      }
    elseif recordType == Sbnk.TYPE_DUMMY then
      instruments[program] = { type = recordType }
    elseif recordType == Sbnk.TYPE_DRUM_SET then
      if offset + 2 > size then
        fail("SBNK_TRUNCATED", "drum set header extends past the end of the bank", {
          source = source,
          sourceOffset = offset,
        })
      end
      local minKey = u8At(bytes, offset, source)
      local maxKey = u8At(bytes, offset + 1, source)
      local leaves = {}
      for key = minKey, maxKey do
        leaves[key - minKey] = readLeaf(bytes, offset + 2 + (key - minKey) * LEAF_SIZE, size, source)
      end
      instruments[program] = { type = recordType, minKey = minKey, maxKey = maxKey, leaves = leaves }
    elseif recordType == Sbnk.TYPE_KEY_SPLIT then
      if offset + 8 > size then
        fail("SBNK_TRUNCATED", "key split header extends past the end of the bank", {
          source = source,
          sourceOffset = offset,
        })
      end
      local keys = {}
      local leafCount = 0
      for i = 0, 7 do
        local key = u8At(bytes, offset + i, source)
        if key == 0 then
          break
        end
        keys[leafCount] = key
        leafCount = leafCount + 1
      end
      if leafCount > 0 then
        local leaves = {}
        for i = 0, leafCount - 1 do
          leaves[i] = readLeaf(bytes, offset + 8 + i * LEAF_SIZE, size, source)
        end
        instruments[program] = { type = recordType, keys = keys, leaves = leaves }
      end
      -- a leafless key split is silent: dropped like a type-0 record
    else
      fail("SBNK_UNSUPPORTED_INSTRUMENT", "unsupported instrument record type", {
        source = source,
        instrument = program,
        sourceOffset = offset,
        type = recordType,
      })
    end
  end

  return { instCount = instCount, instruments = instruments }
end

---@param bytes string
---@param context string?
---@return table?|nil
---@return Errors.Error?|nil
function Sbnk.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Sbnk
