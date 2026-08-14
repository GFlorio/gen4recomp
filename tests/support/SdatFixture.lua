-- Test helper: assemble SDAT sound archives in memory, valid or deliberately
-- malformed. Layout follows the NNS sound archive as GBATEK documents it and
-- as the HGSS dump lays it out: a 0x30 header with SYMB/INFO/FAT/FILE block
-- pointer pairs, INFO holding eight record lists whose slot offsets are
-- INFO-relative (offset 0 = unused slot), FAT entries carrying absolute
-- offsets plus sizes, and embedded files built from the standard 16-byte NNS
-- resource header plus a DATA block.
--
-- SdatFixture.build(spec) returns bytes, layout where archive sections are
-- zero-based slot maps (an absent slot is unused) and layout records the
-- emitted block offsets, file ids, and counts. `spec.payloads[fileId]`
-- replaces an embedded resource wholesale with full NNS resource bytes (the
-- 16-byte header and DATA block included, exactly as Sdat.readFile returns
-- them) for real SSEQ/SBNK/SWAR payloads. SdatFixture.corrupt(bytes, layout,
-- mutation) applies exactly one corruption; mutation keys:
--   { magic=, bom=, version=, declaredSizeTooLarge=, truncated=, headerSize=,
--     blockCount=, symbSizePastEnd=, infoSizePastEnd=, fatSizePastEnd=,
--     fileSizePastEnd=, infoListPastEnd=, missingInfo=, missingFat=,
--     missingFile=, fatCountMismatch=, fileRangePastEnd=, fileIdOutOfRange=,
--     resourceType={class=,id=,magic=}, resourceSizeMismatch={class=,id=} }

local FntWriter = require("tests.support.FntWriter")

local SdatFixture = {}

local u16, u32 = FntWriter.u16, FntWriter.u32

local HEADER_SIZE = 0x30
local INFO_RESERVED = 0x18
local LIST_OFFSET = 0x40 -- INFO lists start after header + reserved padding
local FILE_IMAGE_HEADER = 0x18
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

local RESOURCE_MAGIC = {
  sequences = "SSEQ",
  sequenceArchives = "SSAR",
  banks = "SBNK",
  waveArchives = "SWAR",
  streams = "STRM",
}

local SYMBOL_PREFIX = {
  sequences = "SEQ_",
  sequenceArchives = "SEQARC_",
  banks = "BANK_",
  waveArchives = "WAVE_",
  players = "PLAYER_",
  groups = "GROUP_",
  streamPlayers = "STRMPLY_",
  streams = "STREAM_",
}

SdatFixture.DEFAULT = {
  sequences = {
    [0] = { bankId = 1, volume = 120, channelPriority = 127, playerPriority = 64, playerId = 0 },
    [2] = { bankId = 0, volume = 100, channelPriority = 64, playerPriority = 64, playerId = 1 },
  },
  sequenceArchives = { [0] = {} },
  banks = {
    [0] = { waveArchives = { 1, 0xFFFF, 0xFFFF, 0xFFFF } },
    [1] = { waveArchives = { 0, 0xFFFF, 0xFFFF, 0xFFFF } },
  },
  waveArchives = { [0] = {}, [1] = {} },
  players = { [0] = { maxSequences = 2, channelMask = 0xC000, heapSize = 0x5E88 } },
  groups = { [0] = { entries = { { type = 0, loadFlags = 7, id = 0 } } } },
  streamPlayers = { [0] = { channelCount = 1, leftChannel = 1, rightChannel = 2 } },
  streams = { [0] = { volume = 127, priority = 64, playerId = 0 } },
  extraFiles = 1,
  symbols = true,
}

-- Embedded NNS resource: 16-byte file header plus a DATA block with four
-- zero content bytes.
local function resource(magic)
  local dataBlock = "DATA" .. u32(8) .. "\0\0\0\0"
  return magic .. u16(0xFEFF) .. u16(0x0100) .. u32(16 + #dataBlock) .. u16(0x10) .. u16(1) .. dataBlock
end

local function maxUsedIndex(slots)
  local max = -1
  for id in pairs(slots) do
    max = math.max(max, id)
  end
  return max
end

local function recordBytes(section, record, fileId)
  if section == "sequences" then
    return u16(fileId)
      .. u16(0)
      .. u16(record.bankId or 0)
      .. string.char(
        record.volume or 127,
        record.channelPriority or 64,
        record.playerPriority or 64,
        record.playerId or 0
      )
      .. u16(0)
  end
  if section == "sequenceArchives" then
    return u16(fileId) .. u16(0)
  end
  if section == "banks" then
    local w = record.waveArchives or { 0, 0xFFFF, 0xFFFF, 0xFFFF }
    return u16(fileId) .. u16(0) .. u16(w[1]) .. u16(w[2]) .. u16(w[3]) .. u16(w[4])
  end
  if section == "waveArchives" then
    return u16(fileId) .. u16(0)
  end
  if section == "players" then
    return u16(record.maxSequences or 1) .. u16(record.channelMask or 0x3FFF) .. u32(record.heapSize or 0x1000)
  end
  if section == "groups" then
    local parts = { u32(#record.entries) }
    for _, e in ipairs(record.entries) do
      parts[#parts + 1] = string.char(e.type or 0, e.loadFlags or 7) .. u16(0) .. u32(e.id or 0)
    end
    return table.concat(parts)
  end
  if section == "streamPlayers" then
    return string.char(record.channelCount or 1, record.leftChannel or 1, record.rightChannel or 2)
      .. string.rep("\0", 5)
  end
  if section == "streams" then
    return u16(fileId)
      .. u16(0)
      .. string.char(record.volume or 127, record.priority or 64, record.playerId or 0)
      .. string.rep("\0", 1)
  end
  error("unknown section " .. section)
end

-- Slot counts and file id assignment in FAT order: sequences, sequence
-- archives, banks, wave archives, streams. Extra files are appended after all
-- referenced resources so corrupting them proves FAT ranges are validated even
-- when INFO never references the file.
local function plan(spec)
  local counts, fileIds, files = {}, {}, {}
  local nextFileId = 0
  for _, section in ipairs(SECTION_ORDER) do
    local slots = spec[section] or {}
    counts[section] = maxUsedIndex(slots) + 1
    fileIds[section] = {}
    if RESOURCE_MAGIC[section] then
      for id = 0, counts[section] - 1 do
        if slots[id] ~= nil then
          fileIds[section][id] = nextFileId
          files[nextFileId] = { magic = RESOURCE_MAGIC[section] }
          nextFileId = nextFileId + 1
        end
      end
    end
  end
  for _ = 1, spec.extraFiles or 0 do
    files[nextFileId] = { magic = "SSEQ" }
    nextFileId = nextFileId + 1
  end
  counts.files = nextFileId
  return counts, fileIds, files
end

local function block(counts, magic, buildLists)
  local parts = { magic, u32(0) }
  local listOffsets = {}
  local cursor = LIST_OFFSET
  for _, section in ipairs(SECTION_ORDER) do
    listOffsets[section] = cursor
    cursor = cursor + 4 + 4 * counts[section]
  end
  for _, section in ipairs(SECTION_ORDER) do
    parts[#parts + 1] = u32(listOffsets[section])
  end
  parts[#parts + 1] = string.rep("\0", INFO_RESERVED)
  buildLists(parts, listOffsets, cursor)
  local body = table.concat(parts)
  return magic .. u32(#body) .. body:sub(9), listOffsets
end

local function buildInfo(spec, counts, fileIds)
  return block(counts, "INFO", function(parts, listOffsets, poolStart)
    local pool = {}
    local poolSize = 0
    for _, section in ipairs(SECTION_ORDER) do
      local slotOffsets = {}
      for id = 0, counts[section] - 1 do
        local record = (spec[section] or {})[id]
        if record == nil then
          slotOffsets[id] = 0
        else
          slotOffsets[id] = poolStart + poolSize
          pool[#pool + 1] = recordBytes(section, record, fileIds[section][id])
          poolSize = poolSize + #pool[#pool]
        end
      end
      parts[#parts + 1] = u32(counts[section])
      for id = 0, counts[section] - 1 do
        parts[#parts + 1] = u32(slotOffsets[id])
      end
    end
    for _, chunk in ipairs(pool) do
      parts[#parts + 1] = chunk
    end
  end)
end

local function buildSymbols(spec, counts)
  return block(counts, "SYMB", function(parts, listOffsets, stringStart)
    local strings = {}
    local stringOffset = stringStart
    for _, section in ipairs(SECTION_ORDER) do
      local slotOffsets = {}
      for id = 0, counts[section] - 1 do
        local record = (spec[section] or {})[id]
        if record == nil then
          slotOffsets[id] = 0
        else
          slotOffsets[id] = stringOffset
          strings[#strings + 1] = SYMBOL_PREFIX[section] .. id .. "\0"
          stringOffset = stringOffset + #SYMBOL_PREFIX[section] + #tostring(id) + 1
        end
      end
      parts[#parts + 1] = u32(counts[section])
      for id = 0, counts[section] - 1 do
        parts[#parts + 1] = u32(slotOffsets[id])
      end
    end
    for _, s in ipairs(strings) do
      parts[#parts + 1] = s
    end
  end)
end

function SdatFixture.build(spec)
  spec = spec or {}
  local counts, fileIds, files = plan(spec)

  local symb = nil
  if spec.symbols ~= false then
    symb = buildSymbols(spec, counts)
  end
  local info = buildInfo(spec, counts, fileIds)

  local fatEntries, filePayload = {}, {}
  local payloadPos = 0
  local payloads = spec.payloads or {}
  for fileId = 0, counts.files - 1 do
    -- Custom payloads are full embedded NNS resources (the wrapper included,
    -- as Sdat.readFile returns them); the default is the generic resource.
    local data = payloads[fileId] or resource(files[fileId].magic)
    fatEntries[fileId] = { offset = payloadPos, size = #data }
    filePayload[#filePayload + 1] = data
    payloadPos = payloadPos + #data
  end
  local fileImagePayload = table.concat(filePayload)
  local fileBlock = "FILE"
    .. u32(FILE_IMAGE_HEADER + #fileImagePayload)
    .. u32(counts.files)
    .. u32(0)
    .. string.rep("\0", 8)
    .. fileImagePayload

  local blocks = {}
  local blockOffsets = {}
  local offset = HEADER_SIZE
  if symb then
    blockOffsets.symb = offset
    blocks[#blocks + 1] = symb
    offset = offset + #symb
  end
  blockOffsets.info = offset
  blocks[#blocks + 1] = info
  offset = offset + #info
  blockOffsets.fat = offset
  blocks[#blocks + 1] = "FAT " .. u32(0) .. u32(counts.files) .. string.rep("\0", 16 * counts.files)
  offset = offset + #blocks[#blocks]
  blockOffsets.file = offset
  blocks[#blocks + 1] = fileBlock
  offset = offset + #fileBlock

  local fatBody = "FAT " .. u32(0) .. u32(counts.files)
  for fileId = 0, counts.files - 1 do
    local entry = fatEntries[fileId]
    fatBody = fatBody
      .. u32(blockOffsets.file + FILE_IMAGE_HEADER + entry.offset)
      .. u32(entry.size)
      .. string.rep("\0", 8)
  end
  fatBody = "FAT " .. u32(#fatBody) .. fatBody:sub(9)
  for i, b in ipairs(blocks) do
    if b:sub(1, 4) == "FAT " then
      blocks[i] = fatBody
    end
  end

  local header = "SDAT"
    .. u16(0xFEFF)
    .. u16(0x0100)
    .. u32(offset)
    .. u16(HEADER_SIZE)
    .. u16(#blocks)
    .. u32(blockOffsets.symb or 0)
    .. u32(symb and #symb or 0)
    .. u32(blockOffsets.info)
    .. u32(#info)
    .. u32(blockOffsets.fat)
    .. u32(#fatBody)
    .. u32(blockOffsets.file)
    .. u32(#fileBlock)

  return header .. table.concat(blocks),
    {
      counts = counts,
      fileIds = fileIds,
      blockOffsets = blockOffsets,
      symbPresent = symb ~= nil,
    }
end

local function patch(bytes, pos0, replacement)
  return bytes:sub(1, pos0) .. replacement .. bytes:sub(pos0 + #replacement + 1)
end

local function u16decode(bytes, pos0)
  local b1, b2 = bytes:byte(pos0 + 1, pos0 + 2)
  return b1 + b2 * 256
end

local function u32decode(bytes, pos0)
  local b1, b2, b3, b4 = bytes:byte(pos0 + 1, pos0 + 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function resourceFileId(layout, ref)
  local fileId = layout.fileIds[ref.class] and layout.fileIds[ref.class][ref.id]
  assert(fileId ~= nil, "no file for " .. ref.class .. "[" .. ref.id .. "]")
  return fileId
end

local function fatEntry(bytes, layout, fileId)
  local fat = layout.blockOffsets.fat
  local base = fat + 12 + fileId * 16
  return base, u32decode(bytes, base)
end

function SdatFixture.corrupt(bytes, layout, mutation)
  assert(type(bytes) == "string", "corrupt needs built bytes")
  assert(layout, "corrupt needs the build layout")
  mutation = mutation or {}

  if mutation.magic then
    return patch(bytes, 0, mutation.magic)
  end
  if mutation.bom then
    -- A big-endian archive stores the BOM value 0xFEFF as the byte pair FE FF.
    return patch(bytes, 4, u16(0xFFFE))
  end
  if mutation.version then
    return patch(bytes, 6, u16(mutation.version))
  end
  if mutation.declaredSizeTooLarge then
    return patch(bytes, 8, u32(u32decode(bytes, 8) + 1))
  end
  if mutation.truncated then
    return bytes:sub(1, -2)
  end
  if mutation.headerSize then
    return patch(bytes, 12, u16(mutation.headerSize))
  end
  if mutation.blockCount then
    return patch(bytes, 14, u16(mutation.blockCount))
  end
  if mutation.symbSizePastEnd then
    return patch(bytes, 0x14, u32(0xFFFFFF))
  end
  if mutation.infoSizePastEnd then
    return patch(bytes, 0x1C, u32(0xFFFFFF))
  end
  if mutation.fatSizePastEnd then
    return patch(bytes, 0x24, u32(0xFFFFFF))
  end
  if mutation.fileSizePastEnd then
    return patch(bytes, 0x2C, u32(0xFFFFFF))
  end
  if mutation.infoListPastEnd then
    -- Point the sequence list just past the end of the INFO block.
    local info = layout.blockOffsets.info
    local infoSize = u32decode(bytes, info + 4)
    return patch(bytes, info + 8, u32(infoSize + 4))
  end
  if mutation.missingInfo then
    return patch(bytes, 0x18, u32(0) .. u32(0))
  end
  if mutation.missingFat then
    return patch(bytes, 0x20, u32(0) .. u32(0))
  end
  if mutation.missingFile then
    return patch(bytes, 0x28, u32(0) .. u32(0))
  end
  if mutation.fatCountMismatch then
    local fat = layout.blockOffsets.fat
    return patch(bytes, fat + 8, u32(u32decode(bytes, fat + 8) + 1))
  end
  if mutation.fileRangePastEnd then
    local fat = layout.blockOffsets.fat
    local count = u32decode(bytes, fat + 8)
    local last = fat + 12 + (count - 1) * 16
    return patch(bytes, last + 4, u32(u32decode(bytes, last + 4) + 8))
  end
  if mutation.fileIdOutOfRange then
    -- Point the first sequence record at a file id beyond the FAT table.
    local info = layout.blockOffsets.info
    local seq0 = u32decode(bytes, info + LIST_OFFSET + 4)
    return patch(bytes, info + seq0, u16(0xFFFF))
  end
  if mutation.resourceType then
    local fileId = resourceFileId(layout, mutation.resourceType)
    local _, fileOffset = fatEntry(bytes, layout, fileId)
    return patch(bytes, fileOffset, mutation.resourceType.magic)
  end
  if mutation.resourceSizeMismatch then
    local fileId = resourceFileId(layout, mutation.resourceSizeMismatch)
    local base, fileOffset = fatEntry(bytes, layout, fileId)
    return patch(bytes, fileOffset + 8, u32(u32decode(bytes, base + 4) + 1))
  end
  error("unknown corruption " .. tostring(next(mutation)))
end

return SdatFixture
