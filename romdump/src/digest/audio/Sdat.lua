-- Decodes the NDS sound archive (SDAT) container used by HGSS
-- (data/sound/gs_sound_data.sdat) into zero-based source IR for the audio
-- inventory. Layout per GBATEK "DS Sound Files - SDAT" and the NNS sndarc
-- header: a header with SYMB/INFO/FAT/FILE block pointer pairs, INFO record
-- lists whose slot offsets are INFO-relative (offset 0 = unused), FAT entries
-- carrying absolute offsets plus sizes, and a FILE image of embedded NNS
-- resources. Every referenced embedded resource is validated against its FAT
-- range: the class signature and the resource's declared size must match,
-- otherwise the archive is rejected with the resource class, id, file id,
-- source offset, expected type, and observed type. Pure domain module: no
-- love dependency. All IDs remain zero-based.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")

local Sdat = {}
Sdat.__index = Sdat

local MIN_HEADER_SIZE = 0x30
local BLOCK_ENTRY_SIZE = 8
local FAT_HEADER_SIZE = 12
local FAT_ENTRY_SIZE = 16
local FILE_BLOCK_HEADER = 0x18
local NNS_RESOURCE_HEADER = 0x10

local SECTION_ORDER = {
  "sequences",
  "sequenceArchives",
  "banks",
  "waveArchives",
  "players",
  "groups",
  "streamPlayers",
  "streams",
}

local RECORD_SIZE = {
  sequences = 12,
  sequenceArchives = 4,
  banks = 12,
  waveArchives = 4,
  players = 8,
  streamPlayers = 8,
  streams = 8,
}

local RESOURCE_MAGIC = {
  sequences = "SSEQ",
  sequenceArchives = "SSAR",
  banks = "SBNK",
  waveArchives = "SWAR",
  streams = "STRM",
}

local BLOCK_BOUNDS_CODE = {
  symb = "SDAT_SYMB_BOUNDS",
  info = "SDAT_INFO_BOUNDS",
  fat = "SDAT_FAT_BOUNDS",
  file = "SDAT_FILE_IMAGE_BOUNDS",
}

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

-- Reads the eight record-list pointer tables shared by the INFO and SYMB
-- blocks and bounds-checks every list inside its block. Returns
-- { [section] = { count = count, offsets = { [id] = blockRelativeOffset } } }.
local function parseBlockLists(r, block, context, errorCode)
  local blockSize = block.size
  if blockSize < 0x28 then
    fail(errorCode, "block is smaller than its pointer table", {
      source = context,
      offset = block.offset,
      blockSize = blockSize,
    })
  end
  local lists = {}
  for index, section in ipairs(SECTION_ORDER) do
    local listOffset = r:u32le(block.offset + 8 + (index - 1) * 4)
    if listOffset + 4 > blockSize then
      fail(errorCode, "record list pointer of section " .. section .. " is outside its block", {
        source = context,
        section = section,
        listOffset = listOffset,
        blockSize = blockSize,
      })
    end
    local count = r:u32le(block.offset + listOffset)
    if listOffset + 4 + 4 * count > blockSize then
      fail(errorCode, "record list of section " .. section .. " extends past its block", {
        source = context,
        section = section,
        listOffset = listOffset,
        count = count,
        blockSize = blockSize,
      })
    end
    local offsets = {}
    for id = 0, count - 1 do
      offsets[id] = r:u32le(block.offset + listOffset + 4 + id * 4)
    end
    lists[section] = { count = count, offsets = offsets }
  end
  return lists
end

local function parseRecord(r, block, section, id, slotOffset, context)
  local base = block.offset + slotOffset
  local recordSize = RECORD_SIZE[section]
  if recordSize ~= nil and slotOffset + recordSize > block.size then
    fail("SDAT_INFO_BOUNDS", "record of section " .. section .. " extends past the INFO block", {
      source = context,
      section = section,
      id = id,
      slotOffset = slotOffset,
      blockSize = block.size,
    })
  end
  if section == "sequences" then
    return {
      id = id,
      fileId = r:u16le(base),
      bankId = r:u16le(base + 4),
      volume = r:u8(base + 6),
      channelPriority = r:u8(base + 7),
      playerPriority = r:u8(base + 8),
      playerId = r:u8(base + 9),
    }
  end
  if section == "sequenceArchives" then
    return { id = id, fileId = r:u16le(base) }
  end
  if section == "banks" then
    local waveArchives = {}
    for slot = 0, 3 do
      local waveId = r:u16le(base + 4 + slot * 2)
      if waveId ~= 0xFFFF then
        waveArchives[slot] = waveId
      end
    end
    return { id = id, fileId = r:u16le(base), waveArchives = waveArchives }
  end
  if section == "waveArchives" then
    return { id = id, fileId = r:u16le(base) }
  end
  if section == "players" then
    return {
      id = id,
      maxSequences = r:u16le(base),
      channelMask = r:u16le(base + 2),
      heapSize = r:u32le(base + 4),
    }
  end
  if section == "groups" then
    local count = r:u32le(base)
    if slotOffset + 4 + count * 8 > block.size then
      fail("SDAT_INFO_BOUNDS", "group entry list extends past the INFO block", {
        source = context,
        id = id,
        slotOffset = slotOffset,
        count = count,
        blockSize = block.size,
      })
    end
    local entries = {}
    for entryIndex = 0, count - 1 do
      local entry = base + 4 + entryIndex * 8
      entries[entryIndex + 1] = {
        type = r:u8(entry),
        loadFlags = r:u8(entry + 1),
        id = r:u32le(entry + 4),
      }
    end
    return { id = id, entries = entries }
  end
  if section == "streamPlayers" then
    return {
      id = id,
      channelCount = r:u8(base),
      leftChannel = r:u8(base + 1),
      rightChannel = r:u8(base + 2),
    }
  end
  -- streams
  return {
    id = id,
    fileId = r:u16le(base),
    volume = r:u8(base + 4),
    priority = r:u8(base + 5),
    playerId = r:u8(base + 6),
  }
end

local function parseInfo(r, block, context)
  local lists = parseBlockLists(r, block, context, "SDAT_INFO_BOUNDS")
  local records = {}
  local counts = {}
  for _, section in ipairs(SECTION_ORDER) do
    local list = lists[section]
    counts[section] = list.count
    local sectionRecords = {}
    for id = 0, list.count - 1 do
      local slotOffset = list.offsets[id]
      if slotOffset == 0 then
        sectionRecords[id] = { id = id }
      else
        sectionRecords[id] = parseRecord(r, block, section, id, slotOffset, context)
      end
    end
    records[section] = sectionRecords
  end
  return records, counts
end

local function parseSymbols(r, block, context)
  local lists = parseBlockLists(r, block, context, "SDAT_SYMB_BOUNDS")
  local symbols = {}
  local blockEnd = block.offset + block.size
  for _, section in ipairs(SECTION_ORDER) do
    local list = lists[section]
    local names = {}
    for id = 0, list.count - 1 do
      local offset = list.offsets[id]
      if offset > 0 then
        local nul = string.find(r.data, "\0", block.offset + offset + 1, true)
        if nul == nil or nul > blockEnd then
          fail("SDAT_SYMB_BOUNDS", "symbol string of section " .. section .. " is not terminated inside its block", {
            source = context,
            section = section,
            id = id,
            offset = offset,
          })
        end
        names[id] = string.sub(r.data, block.offset + offset + 1, nul - 1)
      end
    end
    symbols[section] = names
  end
  return symbols
end

---@param r BinaryReader
---@param section string
---@param id integer
---@param fileId integer
---@param entry { offset: integer, size: integer }
---@param context string?
local function validateResource(r, section, id, fileId, entry, context)
  local offset = entry.offset
  if entry.size < NNS_RESOURCE_HEADER then
    fail("SDAT_RESOURCE_SIZE_MISMATCH", "resource of section " .. section .. " is too small to hold an NNS header", {
      source = context,
      resourceClass = section,
      resourceId = id,
      fileId = fileId,
      sourceOffset = offset,
      expectedType = RESOURCE_MAGIC[section],
      actualSize = entry.size,
    })
  end
  local observed = r:bytes(offset, 4)
  local expected = RESOURCE_MAGIC[section]
  if observed ~= expected then
    fail("SDAT_RESOURCE_TYPE_MISMATCH", "resource of section " .. section .. " has the wrong embedded signature", {
      source = context,
      resourceClass = section,
      resourceId = id,
      fileId = fileId,
      sourceOffset = offset,
      expectedType = expected,
      observedType = observed,
    })
  end
  local declaredSize = r:u32le(offset + 8)
  if declaredSize ~= entry.size then
    fail(
      "SDAT_RESOURCE_SIZE_MISMATCH",
      "resource of section " .. section .. " declares a size that does not match its FAT range",
      {
        source = context,
        resourceClass = section,
        resourceId = id,
        fileId = fileId,
        sourceOffset = offset,
        expectedType = expected,
        declaredSize = declaredSize,
        actualSize = entry.size,
      }
    )
  end
end

local function parse(bytes, context)
  if #bytes < MIN_HEADER_SIZE then
    fail("SDAT_TRUNCATED", "SDAT is shorter than its fixed header", {
      source = context,
      expected = MIN_HEADER_SIZE,
      actual = #bytes,
    })
  end
  local r = BinaryReader.new(bytes, context)
  if r:bytes(0, 4) ~= "SDAT" then
    fail("SDAT_BAD_MAGIC", "SDAT signature is missing", {
      source = context,
      offset = 0,
      observed = r:bytes(0, 4),
    })
  end
  if r:u16le(4) ~= 0xFEFF then
    fail("SDAT_BAD_BOM", "SDAT byte order mark is not little-endian", {
      source = context,
      offset = 4,
      observed = r:u16le(4),
    })
  end
  if r:u16le(6) ~= 0x0100 then
    fail("SDAT_UNSUPPORTED_VERSION", "unsupported SDAT version", {
      source = context,
      offset = 6,
      observed = r:u16le(6),
    })
  end
  local declaredSize = r:u32le(8)
  if declaredSize > #bytes then
    fail("SDAT_TRUNCATED", "declared SDAT size exceeds the supplied bytes", {
      source = context,
      declaredSize = declaredSize,
      actual = #bytes,
    })
  end
  local headerSize = r:u16le(12)
  local blockCount = r:u16le(14)
  if blockCount ~= 4 and blockCount ~= 3 then
    fail("SDAT_BAD_BLOCK_COUNT", "unexpected SDAT block count", {
      source = context,
      blockCount = blockCount,
    })
  end
  if headerSize < 0x10 + BLOCK_ENTRY_SIZE * blockCount then
    fail("SDAT_BAD_HEADER_SIZE", "SDAT header is too small for its block table", {
      source = context,
      headerSize = headerSize,
      blockCount = blockCount,
    })
  end

  local blockNames = { "symb", "info", "fat", "file" }
  local blocks = {}
  for index = 0, 3 do
    local name = blockNames[index + 1]
    local offset = r:u32le(0x10 + index * BLOCK_ENTRY_SIZE)
    local size = r:u32le(0x14 + index * BLOCK_ENTRY_SIZE)
    if offset > 0 then
      if offset < headerSize then
        fail("SDAT_BAD_HEADER_SIZE", "SDAT block begins before the header ends", {
          source = context,
          offset = offset,
          headerSize = headerSize,
        })
      end
      if offset + size > declaredSize then
        fail(BLOCK_BOUNDS_CODE[name], "SDAT block extends past the declared file size", {
          source = context,
          offset = offset,
          size = size,
          declaredSize = declaredSize,
        })
      end
      blocks[name] = { offset = offset, size = size }
    end
  end

  local symbols
  if blocks.symb ~= nil then
    symbols = parseSymbols(r, blocks.symb, context)
  end

  local info = blocks.info
  if info == nil then
    fail("SDAT_INFO_BOUNDS", "INFO block is missing", { source = context })
  end
  -- LuaLS cannot see through the raising helper; the assert narrows the block.
  info = assert(info)
  local records, recordCounts = parseInfo(r, info, context)

  local fat = blocks.fat
  if fat == nil then
    fail("SDAT_FAT_BOUNDS", "FAT block is missing", { source = context })
  end
  fat = assert(fat)
  local fatCount = r:u32le(fat.offset + 8)
  if r:u32le(fat.offset + 4) ~= FAT_HEADER_SIZE + fatCount * FAT_ENTRY_SIZE then
    fail("SDAT_FAT_BOUNDS", "FAT size does not match its entry count", {
      source = context,
      blockSize = r:u32le(fat.offset + 4),
      count = fatCount,
    })
  end

  local file = blocks.file
  if file == nil then
    fail("SDAT_FILE_IMAGE_BOUNDS", "FILE block is missing", { source = context })
  end
  file = assert(file)
  local imageStart = file.offset + FILE_BLOCK_HEADER
  local imageEnd = file.offset + file.size
  local files = {}
  for fileId = 0, fatCount - 1 do
    local base = fat.offset + FAT_HEADER_SIZE + fileId * FAT_ENTRY_SIZE
    local offset = r:u32le(base)
    local size = r:u32le(base + 4)
    if offset < imageStart or offset + size > imageEnd then
      fail("SDAT_FILE_RANGE", "FAT range of a file lies outside the FILE image", {
        source = context,
        fileId = fileId,
        offset = offset,
        size = size,
        imageStart = imageStart,
        imageEnd = imageEnd,
      })
    end
    files[fileId] = { offset = offset, size = size }
  end

  local counts = recordCounts
  counts.files = fatCount

  for _, section in ipairs(SECTION_ORDER) do
    if RESOURCE_MAGIC[section] ~= nil then
      for id = 0, counts[section] - 1 do
        local record = records[section][id]
        if record.fileId ~= nil then
          local entry = files[record.fileId]
          if entry == nil then
            fail("SDAT_FILE_ID_OUT_OF_RANGE", "record references a file id beyond the FAT table", {
              source = context,
              resourceClass = section,
              resourceId = id,
              fileId = record.fileId,
              fileCount = fatCount,
            })
          end
          entry = assert(entry)
          validateResource(r, section, id, record.fileId, entry, context)
        end
      end
    end
  end

  return setmetatable({
    source = context,
    counts = counts,
    sequences = records.sequences,
    sequenceArchives = records.sequenceArchives,
    banks = records.banks,
    waveArchives = records.waveArchives,
    players = records.players,
    groups = records.groups,
    streamPlayers = records.streamPlayers,
    streams = records.streams,
    files = files,
    symbols = symbols,
    _bytes = bytes,
  }, Sdat)
end

---@param bytes string
---@param context string?
---@return table|nil
---@return Errors.Error|nil
function Sdat.open(bytes, context)
  assert(type(bytes) == "string", "Sdat.open requires a byte string")
  local ok, result = pcall(parse, bytes, context or "SDAT")
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param fileId integer
---@return string|nil
---@return Errors.Error|nil
function Sdat:readFile(fileId)
  local entry = self.files[fileId]
  if entry == nil then
    return nil,
      Errors.new("SDAT_FILE_ID_OUT_OF_RANGE", "no FAT entry for file " .. tostring(fileId), {
        source = self.source,
        fileId = fileId,
      })
  end
  return string.sub(self._bytes, entry.offset + 1, entry.offset + entry.size)
end

return Sdat
