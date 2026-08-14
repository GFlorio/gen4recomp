-- SDAT (Sound Data Archive) container contract: INFO lists (SSEQ/BANK/SWAR
-- entries), the FAT file table, and BLZ-decoded file access. The header
-- layout follows GBATEK's "DS Sound Files - SDAT"; entries are INFO-relative
-- offsets. Fixtures are built by hand; the real gs_sound_data.sdat gated the
-- same layout.

local Assert = require("tests.support.Assert")
local SdatDecoder = require("romdump.src.digest.SdatDecoder")

local T = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function swap4(s)
  return s:reverse()
end

local function section(magic, payload)
  return magic .. u32(8 + #payload) .. payload
end

-- BLZ wrapper whose stream decodes `data` as literals: a 12-byte header,
-- then flag bytes with literal runs covering the payload (a second all-zero
-- flag byte covers the bytes past the first 8).
local function blz(data)
  return string.char(
    0,
    0,
    0,
    #data % 65536 % 256,
    math.floor(#data / 256) % 256,
    math.floor(#data / 65536) % 256,
    0xC,
    0
  ) .. string.char(0, 0, 0, 0) .. string.char(0) .. data:sub(1, 8) .. string.char(0) .. data:sub(9)
end

-- Minimal SDAT: INFO with three lists (entries stored after the pointers),
-- FAT with N files, FILE payload. `files` maps fileId to raw bytes; entries
-- are built as raw record strings. All INFO pointers are relative to the
-- INFO block start (payload + 8).
-- bank entry: fileId 0; swar entry: fileId 1
local function sdat(lists, files)
  local function list(infoOffset, entries)
    local pointers = {}
    local body = {}
    local base = infoOffset + 4 + #entries * 4
    for _, e in ipairs(entries) do
      pointers[#pointers + 1] = u32(base)
      body[#body + 1] = e
      base = base + #e
    end
    return u32(#entries) .. table.concat(pointers) .. table.concat(body)
  end
  local seqList = list(0x28, lists.seq or {})
  local bankList = list(0x28 + #seqList, lists.bank or {})
  local swarList = list(0x28 + #seqList + #bankList, lists.swar or {})
  -- INFO payload: eight INFO-relative pointers (SSEQ at +0, BANK at +8,
  -- SWAR at +12, the rest unused), then the lists.
  local info = u32(0x28)
    .. u32(0)
    .. u32(0x28 + #seqList)
    .. u32(0x28 + #seqList + #bankList)
    .. string.rep("\0", 16)
    .. seqList
    .. bankList
    .. swarList
  local filePayload = {}
  local fileOffsets = {}
  local offset = 0
  for id, bytes in ipairs(files) do
    fileOffsets[id] = offset
    filePayload[#filePayload + 1] = bytes
    offset = offset + #bytes
  end
  local fileBlock = "FILE" .. u32(12 + offset) .. u32(#files) .. u32(0) .. table.concat(filePayload)
  local infoSection = section("INFO", info)
  local sectionsBody = infoSection .. fileBlock
  -- FAT file offsets are absolute from the SDAT start; the files live at the
  -- FILE section start plus its 0x10-byte header. The FAT size is fixed, so
  -- its absolute position is known before the entry offsets are patched.
  local fatSize = 4 + #files * 16
  local fatSectionSize = 8 + fatSize
  local fileSectionStart = 0x40 + #infoSection + fatSectionSize
  local fat = u32(#files)
  for id = 1, #files do
    fat = fat .. u32(fileSectionStart + 0x10 + fileOffsets[id]) .. u32(#files[id]) .. string.rep("\0", 8)
  end
  local fatSection = section("FAT ", fat)
  sectionsBody = infoSection .. fatSection .. fileBlock
  -- Header: 0x10 basic fields, section table (offset, size) x3, padding to
  -- 0x40, then the sections.
  local header = "SDAT" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x40 + #sectionsBody) .. u16(0x40) .. u16(3)
  local table_ = u32(0x40)
    .. u32(#infoSection)
    .. u32(0x40 + #infoSection)
    .. u32(#fatSection)
    .. u32(0x40 + #infoSection + #fatSection)
    .. u32(#fileBlock)
  return header .. table_ .. string.rep("\0", 0x40 - 0x10 - #table_) .. sectionsBody
end

function T.sequences_resolve_through_info_and_fat()
  local seq = u16(1) .. u16(0) .. u16(1) .. string.char(2, 0, 0, 0) .. u16(0)
  local data = sdat({ seq = { seq }, bank = {}, swar = {} }, { "file-0", blz("SSEQ-data") })
  local s = assert(SdatDecoder.open(data))
  Assert.equal(s:sequenceCount(), 1)
  local info = assert(s:sequence(0))
  Assert.equal(info.fileId, 1)
  Assert.equal(info.bank, 1)
  Assert.equal(info.volume, 2)
  Assert.equal(s:readFile(info.fileId), "SSEQ-data")
end

function T.bank_entries_expose_their_swar_ids()
  local bank = u16(0) .. u16(0) .. u16(0xFFFF) .. u16(0) .. u16(0xFFFF) .. u16(0xFFFF)
  local swar = u16(1) .. u16(0)
  local data = sdat({ seq = {}, bank = { bank }, swar = { swar } }, { "bank-file", "swar-file" })
  local s = assert(SdatDecoder.open(data))
  local b = assert(s:bank(0))
  Assert.equal(b.fileId, 0)
  Assert.deepEqual(b.swarIds, { 0xFFFF, 0, 0xFFFF, 0xFFFF })
  local w = assert(s:swar(0))
  Assert.equal(w.fileId, 1)
  Assert.equal(s:readFile(1), "swar-file")
end

function T.uncompressed_files_are_returned_unchanged()
  local data = sdat({ seq = {}, bank = {}, swar = {} }, { "\1\2\3" })
  local s = assert(SdatDecoder.open(data))
  Assert.equal(s:readFile(0), "\1\2\3")
end

function T.missing_entries_and_files_are_typed()
  local data = sdat({ seq = {}, bank = {}, swar = {} }, { "x" })
  local s = assert(SdatDecoder.open(data))
  local seq, err = s:sequence(5)
  Assert.isNil(seq)
  Assert.equal(assert(err).code, "SDAT_SEQUENCE_MISSING")
  local file, ferr = s:readFile(9)
  Assert.isNil(file)
  Assert.equal(assert(ferr).code, "SDAT_FILE_MISSING")
end

function T.malformed_headers_are_typed()
  local out, err = SdatDecoder.open("not-sdat")
  Assert.isNil(out)
  Assert.equal(assert(err).code, "SDAT_MAGIC_INVALID")
end

function T.blz_wrapped_files_decode()
  local data = sdat({ seq = {}, bank = {}, swar = {} }, { blz("decoded-payload") })
  local s = assert(SdatDecoder.open(data))
  Assert.equal(s:readFile(0), "decoded-payload")
end

return { tests = T }
