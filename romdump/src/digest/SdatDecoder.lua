-- Strict reader for the Nintendo SDAT (Sound Data Archive) container: the
-- INFO lists (SSEQ/BANK/SWAR entries), the FAT file table, and BLZ-compressed
-- file access. Layout follows GBATEK's "DS Sound Files - SDAT": a 0x40-byte
-- header with a section table, INFO/FAT/FILE sections, INFO-relative list
-- offsets, and 16-byte FAT entries. The runtime never reads this; the
-- FieldUiCompiler resolves the three Start Menu effects from it. Pure module:
-- no love dependency.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local SdatDecoder = {}
SdatDecoder.__index = SdatDecoder

local HEADER_SIZE = 0x40

local function blzDecode(data)
  local function u24(offset)
    return string.byte(data, offset + 1) + string.byte(data, offset + 2) * 256 + string.byte(data, offset + 3) * 65536
  end
  if
    #data < 12
    or string.byte(data, 1) ~= 0
    or string.byte(data, 2) ~= 0
    or string.byte(data, 3) ~= 0
    or string.byte(data, 7) ~= 0xC
  then
    return data
  end
  local outputSize = u24(3)
  local output = {}
  local src = 13
  local dst = 1
  while dst <= outputSize do
    local flags = string.byte(data, src)
    src = src + 1
    for bit = 7, 0, -1 do
      if dst > outputSize then
        break
      end
      if math.floor(flags / 2 ^ bit) % 2 == 0 then
        output[dst] = string.byte(data, src)
        src = src + 1
        dst = dst + 1
      else
        local b1 = string.byte(data, src)
        local b2 = string.byte(data, src + 1)
        src = src + 2
        local length = math.floor(b1 / 16) + 3
        local displacement = (b1 % 16) * 256 + b2 + 1
        if output[dst - displacement] == nil then
          Errors.raise("SDAT_BLZ_INVALID", "BLZ match reaches before the decoded start", {
            dst = dst,
            displacement = displacement,
          })
        end
        for _ = 1, length do
          output[dst] = output[dst - displacement]
          dst = dst + 1
        end
      end
    end
  end
  local chunks = {}
  for i = 1, outputSize do
    chunks[i] = string.char(output[i])
  end
  return table.concat(chunks)
end

local function _open(data, label)
  local reader = BinaryReader.new(data, label or "sdat")
  if reader:length() < HEADER_SIZE or reader:ascii(0, 4) ~= "SDAT" then
    Errors.raise("SDAT_MAGIC_INVALID", "missing SDAT header", { size = reader:length() })
  end
  if reader:u16le(4) ~= 0xFEFF then
    Errors.raise("SDAT_BYTE_ORDER_INVALID", "SDAT byte order is not 0xFEFF", { byteOrder = reader:u16le(4) })
  end
  local declaredSize = reader:u32le(8)
  if declaredSize > reader:length() then
    Errors.raise("SDAT_TRUNCATED", "SDAT declares " .. declaredSize .. " bytes but has " .. reader:length(), {
      declared = declaredSize,
      size = reader:length(),
    })
  end
  -- Section table at 0x10: 4+4 per section (offset, size); the section
  -- magic lives at the recorded offset. The table may carry a SYMB section
  -- before INFO/FAT/FILE.
  local sectionAt = {}
  local sectionCount = reader:u16le(0x0E)
  for i = 1, sectionCount do
    local entry = 0x10 + (i - 1) * 8
    local offset = reader:u32le(entry)
    local name = reader:ascii(offset, 4)
    sectionAt[name] = { offset = offset, size = reader:u32le(entry + 4) }
  end
  local function section(magic)
    local found = sectionAt[magic]
    if not found then
      Errors.raise("SDAT_SECTION_INVALID", "missing " .. magic .. " section", {})
    end
    return found
  end
  local infoBlock = section("INFO").offset
  local fatStart = section("FAT ").offset + 8
  local function infoPtr(index)
    return infoBlock + reader:u32le(infoBlock + 8 + (index - 1) * 4)
  end
  local function listEntries(listPtr)
    local count = reader:u32le(listPtr)
    local entries = {}
    for i = 0, count - 1 do
      entries[i] = infoBlock + reader:u32le(listPtr + 4 + i * 4)
    end
    return { entries = entries, count = count }
  end
  local seqList = listEntries(infoPtr(1))
  local bankList = listEntries(infoPtr(3))
  local swarList = listEntries(infoPtr(4))
  local fatCount = reader:u32le(fatStart)
  local fatEntries = {}
  for fileId = 0, fatCount - 1 do
    local base = fatStart + 4 + fileId * 16
    fatEntries[fileId] = { offset = reader:u32le(base), size = reader:u32le(base + 4) }
  end
  return setmetatable({
    _reader = reader,
    _seqEntries = seqList.entries,
    _seqCount = seqList.count,
    _bankEntries = bankList.entries,
    _bankCount = bankList.count,
    _swarEntries = swarList.entries,
    _swarCount = swarList.count,
    _fat = fatEntries,
  }, SdatDecoder)
end

function SdatDecoder.open(data, label)
  assert(type(data) == "string", "SdatDecoder.open requires a string")
  local ok, result = pcall(_open, data, label)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

function SdatDecoder:sequenceCount()
  return self._seqCount
end
function SdatDecoder:bankCount()
  return self._bankCount
end
function SdatDecoder:swarCount()
  return self._swarCount
end

-- SSEQ info entry: u16 fileId, u16 unknown, u16 bank, u8 volume, u8 cpr,
-- u8 ppr, u8 ply, u16 unknown (GBATEK SSEQ Info Entry).
function SdatDecoder:sequence(seqId)
  local p = self._seqEntries[seqId]
  if not p then
    return nil, Errors.new("SDAT_SEQUENCE_MISSING", "no SSEQ info entry " .. tostring(seqId), { seqId = seqId })
  end
  return {
    fileId = self._reader:u16le(p),
    bank = self._reader:u16le(p + 4),
    volume = string.byte(self._reader:bytes(p + 6, 1)),
  }
end

-- BANK info entry: u16 fileId, u16 unknown, then four u16 SWAR ids
-- (0xFFFF = unused).
function SdatDecoder:bank(bankId)
  local p = self._bankEntries[bankId]
  if not p then
    return nil, Errors.new("SDAT_BANK_MISSING", "no BANK info entry " .. tostring(bankId), { bankId = bankId })
  end
  local swarIds = {}
  for i = 1, 4 do
    swarIds[i] = self._reader:u16le(p + 4 + (i - 1) * 2)
  end
  return { fileId = self._reader:u16le(p), swarIds = swarIds }
end

-- SWAR info entry: u16 fileId, u16 unknown.
function SdatDecoder:swar(swarId)
  local p = self._swarEntries[swarId]
  if not p then
    return nil, Errors.new("SDAT_SWAR_MISSING", "no SWAR info entry " .. tostring(swarId), { swarId = swarId })
  end
  return { fileId = self._reader:u16le(p) }
end

-- Read and BLZ-decode one FAT file.
function SdatDecoder:readFile(fileId)
  local entry = self._fat[fileId]
  if not entry then
    return nil, Errors.new("SDAT_FILE_MISSING", "no FAT entry " .. tostring(fileId), { fileId = fileId })
  end
  local data = self._reader:bytes(entry.offset, entry.size)
  local ok, result = pcall(blzDecode, data)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return SdatDecoder
