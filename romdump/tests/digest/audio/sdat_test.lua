-- SDAT container parsing contract: every malformed offset/length case must
-- fail with a structured Errors object carrying a documented code, never with
-- Lua string-slicing behavior. Synthetic archives come from
-- tests.support.SdatFixture; the production parser
-- (romdump.src.digest.audio.Sdat) implements this contract for the audio
-- inventory work. References: GBATEK "DS Sound Files - SDAT", NNS sndarc
-- headers, and the HGSS dump layout (INFO slot offset 0 = unused).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Sdat = require("romdump.src.digest.audio.Sdat")
local SdatFixture = require("tests.support.SdatFixture")

local T = {}

---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local function openOrFail(bytes)
  local sdat, err = Sdat.open(bytes, "fixture")
  Assert.notNil(sdat, "expected open to succeed: " .. tostring(err))
  return assert(sdat)
end

local function rejects(code, mutation, spec)
  local bytes, layout = SdatFixture.build(spec or SdatFixture.DEFAULT)
  local sdat, err = Sdat.open(SdatFixture.corrupt(bytes, layout, mutation), "fixture")
  Assert.isNil(sdat, "expected open to fail with " .. code)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(asError(err).code, code)
  return asError(err)
end

function T.parses_full_archive_ir_shape()
  local sdat = openOrFail(SdatFixture.build(SdatFixture.DEFAULT))
  Assert.equal(sdat.counts.sequences, 3)
  Assert.equal(sdat.counts.sequenceArchives, 1)
  Assert.equal(sdat.counts.banks, 2)
  Assert.equal(sdat.counts.waveArchives, 2)
  Assert.equal(sdat.counts.players, 1)
  Assert.equal(sdat.counts.groups, 1)
  Assert.equal(sdat.counts.streamPlayers, 1)
  Assert.equal(sdat.counts.streams, 1)
  Assert.equal(sdat.counts.files, 9)

  local seq0 = sdat.sequences[0]
  Assert.equal(seq0.id, 0)
  Assert.equal(seq0.fileId, 0)
  Assert.equal(seq0.bankId, 1)
  Assert.equal(seq0.volume, 120)
  Assert.equal(seq0.channelPriority, 127)
  Assert.equal(seq0.playerPriority, 64)
  Assert.equal(seq0.playerId, 0)
  Assert.equal(sdat.sequences[2].bankId, 0)
  Assert.equal(sdat.sequenceArchives[0].fileId, 2)

  local bank0 = sdat.banks[0]
  Assert.equal(bank0.id, 0)
  Assert.equal(bank0.fileId, 3)
  Assert.deepEqual(bank0.waveArchives, { [0] = 1, [1] = nil, [2] = nil, [3] = nil })
  Assert.deepEqual(sdat.banks[1].waveArchives, { [0] = 0, [1] = nil, [2] = nil, [3] = nil })

  Assert.equal(sdat.waveArchives[0].fileId, 5)
  Assert.equal(sdat.waveArchives[1].fileId, 6)

  local player0 = sdat.players[0]
  Assert.equal(player0.maxSequences, 2)
  Assert.equal(player0.channelMask, 0xC000)
  Assert.equal(player0.heapSize, 0x5E88)

  Assert.equal(#sdat.groups[0].entries, 1)
  Assert.deepEqual(sdat.groups[0].entries[1], { type = 0, loadFlags = 7, id = 0 })

  Assert.equal(sdat.streamPlayers[0].channelCount, 1)
  Assert.equal(sdat.streams[0].fileId, 7)
end

function T.parses_without_symbol_block()
  local bytes, layout = SdatFixture.build({ symbols = false, sequences = { [0] = {} } })
  Assert.equal(layout.symbPresent, false)
  local sdat = openOrFail(bytes)
  Assert.isNil(sdat.symbols)
end

function T.exposes_symbol_names_per_section()
  local sdat = openOrFail(SdatFixture.build(SdatFixture.DEFAULT))
  Assert.notNil(sdat.symbols)
  Assert.equal(sdat.symbols.sequences[0], "SEQ_0")
  Assert.equal(sdat.symbols.sequences[2], "SEQ_2")
  Assert.equal(sdat.symbols.banks[1], "BANK_1")
  Assert.equal(sdat.symbols.waveArchives[0], "WAVE_0")
end

function T.unused_slots_have_no_file_id()
  local sdat = openOrFail(SdatFixture.build(SdatFixture.DEFAULT))
  Assert.isNil(sdat.sequences[1].fileId)
  Assert.equal(sdat.sequences[1].id, 1)
  Assert.isNil(sdat.banks[1].waveArchives[1])
end

function T.reads_embedded_files_by_id()
  local sdat = openOrFail(SdatFixture.build(SdatFixture.DEFAULT))
  local seqFile = assert(sdat:readFile(0))
  Assert.equal(seqFile:sub(1, 4), "SSEQ")
  local data, err = sdat:readFile(999)
  Assert.isNil(data)
  Assert.equal(asError(err).code, "SDAT_FILE_ID_OUT_OF_RANGE")
end

function T.validates_every_embedded_file_range_even_unreferenced()
  local bytes, layout = SdatFixture.build(SdatFixture.DEFAULT)
  local sdat = openOrFail(bytes)
  -- The extra file is referenced by no INFO record but its FAT range must
  -- still be validated; the fixture's last file id is the extra file.
  local files = sdat.files
  Assert.notNil(files[layout.counts.files - 1])
  rejects("SDAT_FILE_RANGE", { fileRangePastEnd = true })
end

function T.rejects_bad_magic()
  rejects("SDAT_BAD_MAGIC", { magic = "XXXX" })
end

function T.rejects_big_endian_bom()
  rejects("SDAT_BAD_BOM", { bom = true })
end

function T.rejects_unsupported_version()
  rejects("SDAT_UNSUPPORTED_VERSION", { version = 0x0200 })
end

function T.rejects_declared_size_past_supplied_bytes()
  rejects("SDAT_TRUNCATED", { declaredSizeTooLarge = true })
end

function T.rejects_truncated_buffer()
  rejects("SDAT_TRUNCATED", { truncated = true })
end

function T.rejects_header_size_not_matching_block_layout()
  rejects("SDAT_BAD_HEADER_SIZE", { headerSize = 0x20 })
  rejects("SDAT_BAD_HEADER_SIZE", { headerSize = 0x50 })
end

function T.rejects_bad_block_count()
  rejects("SDAT_BAD_BLOCK_COUNT", { blockCount = 2 })
  rejects("SDAT_BAD_BLOCK_COUNT", { blockCount = 5 })
end

function T.rejects_symb_out_of_bounds()
  rejects("SDAT_SYMB_BOUNDS", { symbSizePastEnd = true })
end

function T.rejects_info_out_of_bounds()
  rejects("SDAT_INFO_BOUNDS", { infoSizePastEnd = true })
  rejects("SDAT_INFO_BOUNDS", { infoListPastEnd = true })
  rejects("SDAT_INFO_BOUNDS", { missingInfo = true })
end

function T.rejects_fat_out_of_bounds()
  rejects("SDAT_FAT_BOUNDS", { fatSizePastEnd = true })
  rejects("SDAT_FAT_BOUNDS", { missingFat = true })
end

function T.rejects_file_image_out_of_bounds()
  rejects("SDAT_FILE_IMAGE_BOUNDS", { fileSizePastEnd = true })
  rejects("SDAT_FILE_IMAGE_BOUNDS", { missingFile = true })
end

function T.rejects_fat_count_mismatch()
  rejects("SDAT_FAT_BOUNDS", { fatCountMismatch = true })
end

-- A2: a used record whose file id lies beyond the FAT table fails with a
-- structured error naming the record, never a raw indexing failure.
function T.rejects_file_id_out_of_fat_range()
  local err = rejects("SDAT_FILE_ID_OUT_OF_RANGE", { fileIdOutOfRange = true })
  Assert.equal(err.context.resourceClass, "sequences")
  Assert.equal(err.context.resourceId, 0)
  Assert.notNil(err.context.fileCount, "file count present")
end

local RESOURCE_CLASSES = {
  { class = "sequences", expected = "SSEQ" },
  { class = "sequenceArchives", expected = "SSAR" },
  { class = "banks", expected = "SBNK" },
  { class = "waveArchives", expected = "SWAR" },
  { class = "streams", expected = "STRM" },
}

-- A2: a referenced resource whose embedded signature does not match its INFO
-- class is rejected, with an error naming the resource class, resource id,
-- file id, source offset, expected type, and observed type.
function T.rejects_resource_type_mismatch_with_full_context()
  for _, cls in ipairs(RESOURCE_CLASSES) do
    local expected = cls.expected
    local observed = expected == "SSEQ" and "SBNK" or "SSEQ"
    local err = rejects("SDAT_RESOURCE_TYPE_MISMATCH", {
      resourceType = { class = cls.class, id = 0, magic = observed },
    })
    Assert.equal(err.context.resourceClass, cls.class)
    Assert.equal(err.context.resourceId, 0)
    Assert.notNil(err.context.fileId, "file id present")
    Assert.notNil(err.context.sourceOffset, "source offset present")
    Assert.equal(err.context.expectedType, expected)
    Assert.equal(err.context.observedType, observed)
  end
end

-- A2: the embedded resource's own declared size must equal its FAT range.
function T.rejects_resource_declared_size_mismatch()
  for _, cls in ipairs(RESOURCE_CLASSES) do
    local err = rejects("SDAT_RESOURCE_SIZE_MISMATCH", {
      resourceSizeMismatch = { class = cls.class, id = 0 },
    })
    Assert.equal(err.context.resourceClass, cls.class)
    Assert.equal(err.context.resourceId, 0)
    Assert.notNil(err.context.sourceOffset, "source offset present")
  end
end

return { tests = T }
