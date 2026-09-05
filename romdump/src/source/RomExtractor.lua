-- Materializes a parsed NdsRom as a staged raw dump and publishes it over the
-- live per-version cache: a lossless raw NitroFS dump plus deterministic
-- generated metadata, finished by a marker-last transaction. The live dump is
-- not touched until the staged tree is complete and validated; a failed
-- extraction removes the failed staging tree immediately rather than leaving
-- it for the next import. Publication is a separate step from staging: once
-- publish begins, the cache owns the recovery material and a failed publish
-- (or an incomplete rollback) leaves that material in place instead of
-- removing it here. Only after the staged tree lands is the previous version
-- root removed. Orchestration only; all binary parsing lives in the pure
-- modules it drives. run() returns (report | nil, err); the completion marker
-- is written last inside staging, and the staged tree is then published.
--
-- This module is allowed to hold the full ROM (via NdsRom); releasing it is the
-- caller's responsibility. Responsiveness/yielding belongs to the
-- importer coroutine that drives the progress callback, not here.

local Errors = require("libs.errors.src.Errors")
local Narc = require("libs.nds.src.nitro.Narc")
local CacheFs = require("libs.storage.src.CacheFs")
local MapMatrix = require("romdump.src.digest.map.MapMatrix")
local RawDumpContract = require("romdump.src.source.RawDumpContract")

local RomExtractor = {}
RomExtractor.__index = RomExtractor

-- Raw-dump cache format. Independent of any future decoded-data format; bump
-- only when the dump layout or romfs_index schema changes.
RomExtractor.DUMP_FORMAT = 1

-- Extractor error identifiers, centralized in one module-local table.
local EXTRACT_ERROR_CODES = {
  READ_FAILED = "EXTRACT_READ_FAILED",
  WRITE_SIZE_MISMATCH = "EXTRACT_WRITE_SIZE_MISMATCH",
  REQUIRED_NARC_MISSING = "EXTRACT_REQUIRED_NARC_MISSING",
  REQUIRED_NARC_INVALID = "EXTRACT_REQUIRED_NARC_INVALID",
  SMOKE_READ_FAILED = "EXTRACT_SMOKE_READ_FAILED",
  SMOKE_DECODE_FAILED = "EXTRACT_SMOKE_DECODE_FAILED",
  OUTPUT_MISSING = "EXTRACT_OUTPUT_MISSING",
}

function RomExtractor.markerContent(versionId, sha1)
  return "g4-rom-dump-v" .. RomExtractor.DUMP_FORMAT .. ":" .. versionId .. ":" .. sha1
end

-- Ordered stages with the [start, finish) fraction each occupies of the overall
-- progress bar. Monotonic by construction.
local STAGES = {
  { key = "prepare", label = "Preparing staging", from = 0.00, to = 0.02 },
  { key = "write_system_metadata", label = "Writing system data", from = 0.02, to = 0.10 },
  { key = "dump_files", label = "Dumping NitroFS", from = 0.10, to = 0.80 },
  { key = "write_indexes", label = "Writing indexes", from = 0.80, to = 0.88 },
  { key = "validate_narcs", label = "Validating NARCs", from = 0.88, to = 0.94 },
  { key = "smoke_decode", label = "Decoding map matrix", from = 0.94, to = 0.97 },
  { key = "finalize", label = "Finalizing", from = 0.97, to = 0.99 },
  { key = "publish", label = "Publishing dump", from = 0.99, to = 1.00 },
}
local STAGE_BY_KEY = {}
for _, s in ipairs(STAGES) do
  STAGE_BY_KEY[s.key] = s
end

function RomExtractor.new(ndsRom, versionInfo, cache, manifest, progressCallback)
  assert(
    ndsRom and versionInfo and cache and manifest,
    "RomExtractor.new requires ndsRom, versionInfo, cache, manifest"
  )
  return setmetatable({
    _rom = ndsRom,
    _version = versionInfo,
    _cache = cache,
    -- Staging shares the live cache's backend: both roots live in the same
    -- save directory, so the publish renames stay on one filesystem.
    _stage = CacheFs.forStaging(versionInfo.id, cache.backend),
    _manifest = manifest,
    _progress = progressCallback,
  }, RomExtractor)
end

function RomExtractor:_emit(stageKey, current, total, detail)
  if not self._progress then
    return
  end
  local s = STAGE_BY_KEY[stageKey]
  local frac = total > 0 and (current / total) or 1
  self._progress({
    stage = stageKey,
    stageLabel = s.label,
    current = current,
    total = total,
    overall = s.from + (s.to - s.from) * frac,
    detail = detail,
  })
end

local function readRom(rom, offset, length, name)
  local bytes, err = rom:read(offset, length)
  if not bytes then
    Errors.raise(EXTRACT_ERROR_CODES.READ_FAILED, name .. ": " .. Errors.format(err), { section = name })
  end
  return bytes
end

-- Stage 1: drop any stale staging output (including an orphaned previous root
-- from a crash mid-publish), then recreate the staging directories. The live
-- version root is untouched until the completed stage is published.
function RomExtractor:_prepare()
  self._cache:removeStagedTree(self._stage)
  for _, dir in ipairs({
    "data/generated",
    "romfs",
    "system",
    "system/overlay9",
    "system/overlay7",
    "system/unmapped",
  }) do
    self._stage:createDirectory(dir)
  end
  self:_emit("prepare", 1, 1)
end

-- Stage 2: raw header, FNT, FAT, overlay tables, and ARM binaries.
function RomExtractor:_writeSystemMetadata()
  local rom, h = self._rom, self._rom:header()
  self._stage:write("system/header.bin", readRom(rom, 0, 0x200, "header"))
  self._stage:write("system/fnt.bin", readRom(rom, h.fnt.offset, h.fnt.size, "fnt"))
  self._stage:write("system/fat.bin", readRom(rom, h.fat.offset, h.fat.size, "fat"))
  self._stage:write(
    "system/arm9_overlay_table.bin",
    readRom(rom, h.arm9Overlays.offset, h.arm9Overlays.size, "arm9_overlay_table")
  )
  self._stage:write(
    "system/arm7_overlay_table.bin",
    readRom(rom, h.arm7Overlays.offset, h.arm7Overlays.size, "arm7_overlay_table")
  )
  self._stage:write("system/arm9.bin", readRom(rom, h.arm9.offset, h.arm9.size, "arm9"))
  self._stage:write("system/arm7.bin", readRom(rom, h.arm7.offset, h.arm7.size, "arm7"))
  self:_emit("write_system_metadata", 1, 1)
end

-- Stage 3: write every FAT entry exactly once at its resolved destination,
-- validating the landed size. Returns the file map and total bytes written.
function RomExtractor:_dumpFiles()
  local rom = self._rom
  local map = rom:fileMap()
  local total = rom:fatCount()
  local totalBytes, unmapped = 0, 0
  for fileId = 0, total - 1 do
    local dest = map[fileId]
    local data = rom:readFatFile(fileId)
    self._stage:write(dest.path, data)
    local info = self._stage:getInfo(dest.path)
    if not info or info.size ~= dest.size then
      Errors.raise(
        EXTRACT_ERROR_CODES.WRITE_SIZE_MISMATCH,
        "wrote " .. tostring(info and info.size) .. " bytes to " .. dest.path .. ", expected " .. dest.size,
        { path = dest.path, fileId = fileId, expected = dest.size, actual = info and info.size }
      )
    end
    totalBytes = totalBytes + dest.size
    if dest.kind == "unmapped" then
      unmapped = unmapped + 1
    end
    if fileId % 16 == 0 or fileId == total - 1 then
      self:_emit("dump_files", fileId + 1, total, dest.path)
    end
  end
  return map, total, totalBytes, unmapped
end

-- Stage 4: rom_metadata, romfs_index, overlay_index.
function RomExtractor:_writeIndexes(map, fileCount, totalBytes, unmappedCount)
  local rom, h, v = self._rom, self._rom:header(), self._version
  local arm9Ov, arm7Ov = rom:arm9Overlays(), rom:arm7Overlays()
  local namedCount = rom:nitroFs().namedFileCount

  self._stage:writeLua(RawDumpContract.METADATA_PATH, {
    schema = RawDumpContract.METADATA_SCHEMA,
    version = v.id,
    displayName = v.displayName,
    sha1 = v.sha1,
    size = rom:size(),
    title = h.title,
    gameCode = h.gameCode,
    makerCode = h.makerCode,
    unitCode = h.unitCode,
    romVersion = h.romVersion,
    headerSize = h.headerSize,
    usedRomSize = h.usedRomSize,
    arm9 = {
      offset = h.arm9.offset,
      size = h.arm9.size,
      entryAddress = h.arm9.entryAddress,
      ramAddress = h.arm9.ramAddress,
    },
    arm7 = {
      offset = h.arm7.offset,
      size = h.arm7.size,
      entryAddress = h.arm7.entryAddress,
      ramAddress = h.arm7.ramAddress,
    },
    fnt = { offset = h.fnt.offset, size = h.fnt.size },
    fat = { offset = h.fat.offset, size = h.fat.size },
    arm9Overlays = { offset = h.arm9Overlays.offset, size = h.arm9Overlays.size },
    arm7Overlays = { offset = h.arm7Overlays.offset, size = h.arm7Overlays.size },
  })

  local files = {}
  for fileId = 0, fileCount - 1 do
    local dest = map[fileId]
    files[fileId] = {
      fileId = fileId,
      path = dest.path,
      sourcePath = dest.sourcePath,
      offset = dest.offset,
      size = dest.size,
      kind = dest.kind,
      overlayId = dest.overlayId,
    }
  end
  self._stage:writeLua(RawDumpContract.ROMFS_INDEX_PATH, {
    schema = RawDumpContract.ROMFS_INDEX_SCHEMA,
    version = v.id,
    romSha1 = v.sha1,
    fileCount = fileCount,
    namedFileCount = namedCount,
    overlayFileCount = #arm9Ov + #arm7Ov,
    unmappedFileCount = unmappedCount,
    totalFileBytes = totalBytes,
    files = files,
  })

  local function overlayTable(list)
    local out = {}
    for _, ov in ipairs(list) do
      out[ov.overlayId] = {
        overlayId = ov.overlayId,
        fileId = ov.fileId,
        ramAddress = ov.ramAddress,
        ramSize = ov.ramSize,
        bssSize = ov.bssSize,
        staticInitStart = ov.staticInitStart,
        staticInitEnd = ov.staticInitEnd,
        flags = ov.flags,
      }
    end
    return out
  end
  self._stage:writeLua(RawDumpContract.OVERLAY_INDEX_PATH, {
    schema = RawDumpContract.OVERLAY_INDEX_SCHEMA,
    arm9 = overlayTable(arm9Ov),
    arm7 = overlayTable(arm7Ov),
  })

  self:_emit("write_indexes", 1, 1)
end

-- Stage 5: resolve every curated alias through the parsed FNT and open it as a
-- NARC, proving the required archives are present and valid before the marker
-- is written. Required aliases that fail to resolve or open abort the import;
-- optional ones only produce warnings. This is a validation pass only: alias ->
-- fileId resolution is derived at runtime from the manifest plus the FNT index,
-- so nothing is persisted here. Returns the required count, warnings, and the
-- opened NARCs (reused by the smoke decode).
function RomExtractor:_validateNarcs()
  local byPath = self._rom:nitroFs().byPath
  local opened, warnings = {}, {}
  local requiredCount = 0

  for _, entry in ipairs(self._manifest.aliasList()) do
    local fileId = byPath[entry.path]
    if not fileId then
      if entry.required then
        Errors.raise(
          EXTRACT_ERROR_CODES.REQUIRED_NARC_MISSING,
          "required NARC " .. entry.symbol .. " path " .. entry.path .. " not in FNT",
          { symbol = entry.symbol, path = entry.path }
        )
      end
      warnings[#warnings + 1] = "unresolved optional NARC " .. entry.symbol .. " (" .. entry.path .. ")"
    else
      local narc, err = Narc.open(self._rom:readFatFile(fileId), entry.path)
      if not narc then
        if entry.required then
          Errors.raise(
            EXTRACT_ERROR_CODES.REQUIRED_NARC_INVALID,
            "required NARC " .. entry.symbol .. " (" .. entry.path .. ") failed to open: " .. Errors.format(err),
            { symbol = entry.symbol, path = entry.path, fileId = fileId }
          )
        end
        warnings[#warnings + 1] = "non-NARC optional entry " .. entry.symbol .. " (" .. entry.path .. ")"
      else
        opened[entry.alias] = narc
        if entry.required then
          requiredCount = requiredCount + 1
        end
      end
    end
  end

  self:_emit("validate_narcs", 1, 1)
  return requiredCount, warnings, opened
end

-- Stage 6: prove a NARC member decodes through the runtime data layout by
-- reading map_matrices member 0.
function RomExtractor:_smokeDecode(openedNarcs)
  local narc = openedNarcs.map_matrices
  assert(narc, "map_matrices must have been opened as a required NARC")
  local member, err = narc:readMember(0)
  if not member then
    Errors.raise(EXTRACT_ERROR_CODES.SMOKE_READ_FAILED, "map_matrices member 0: " .. Errors.format(err), {})
  end
  local matrix, decodeErr = MapMatrix.decode(member, 0)
  if not matrix then
    Errors.raise(
      EXTRACT_ERROR_CODES.SMOKE_DECODE_FAILED,
      "map_matrices member 0 did not decode: " .. Errors.format(decodeErr),
      {}
    )
  end
  -- LuaLS cannot see through Errors.raise; the assert narrows the decode.
  matrix = assert(matrix)
  self:_emit("smoke_decode", 1, 1)
  return {
    name = matrix.name,
    width = matrix.width,
    height = matrix.height,
    modelCellCount = matrix.width * matrix.height,
  }
end

-- Stage 7: write import_report, recheck the required outputs against staging,
-- then write the staging marker last.
function RomExtractor:_finalize(report)
  self._stage:writeLua("data/generated/import_report.lua", report)

  for _, path in ipairs({
    RawDumpContract.METADATA_PATH,
    RawDumpContract.ROMFS_INDEX_PATH,
    RawDumpContract.OVERLAY_INDEX_PATH,
  }) do
    if not self._stage:exists(path, "file") then
      Errors.raise(EXTRACT_ERROR_CODES.OUTPUT_MISSING, "required output missing at finalize: " .. path, { path = path })
    end
  end

  self._stage:write(RawDumpContract.MARKER_PATH, RomExtractor.markerContent(self._version.id, self._version.sha1))
  self:_emit("finalize", 1, 1)
end

-- Stage 8: move the completed staging tree over the live version root. Only
-- after the staged tree lands is the previous dump removed, so a failed
-- extraction or publish leaves the previous ready dump usable.
function RomExtractor:_publish()
  self._cache:publishFromStage(self._stage)
  self:_emit("publish", 1, 1)
end

-- Stage 1-7: build and validate the staged dump, returning the import report.
-- Nothing in here touches the live tree, so a failure owns the disposable
-- staging tree: run() removes it. Publication is deliberately not part of this
-- step (see run()).
function RomExtractor:_stageDump()
  self:_prepare()
  self:_writeSystemMetadata()
  local map, fileCount, totalBytes, unmappedCount = self:_dumpFiles()
  self:_writeIndexes(map, fileCount, totalBytes, unmappedCount)
  local requiredCount, warnings, opened = self:_validateNarcs()
  local matrix = self:_smokeDecode(opened)

  local report = {
    cacheFormat = RomExtractor.DUMP_FORMAT,
    version = self._version.id,
    sha1 = self._version.sha1,
    fatEntryCount = fileCount,
    namedFileCount = self._rom:nitroFs().namedFileCount,
    arm9OverlayCount = #self._rom:arm9Overlays(),
    arm7OverlayCount = #self._rom:arm7Overlays(),
    unmappedFileCount = unmappedCount,
    totalBytesWritten = totalBytes,
    resolvedRequiredNarcCount = requiredCount,
    narcWarnings = warnings,
    matrix = matrix,
  }
  self:_finalize(report)
  return report
end

function RomExtractor:run()
  local ok, result = pcall(self._stageDump, self)
  if not ok then
    -- The extractor owns its staging tree until publication begins: a failed
    -- staging removes it immediately instead of leaving it for the next import
    -- to discard. removeStagedTree also drops an orphaned `<stagingRoot>.old`
    -- sibling. If removing staging itself fails, that failure propagates -- the
    -- no-stale-staging invariant was not met.
    self._cache:removeStagedTree(self._stage)
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  -- Publication is outside the staging catch: once publish begins, the cache
  -- owns the rollback/recovery material and this module must not remove the
  -- staging tree, or it could delete the last remaining copy of the previous
  -- dump.
  local publishOk, pubErr = pcall(self._publish, self)
  if not publishOk then
    if Errors.is(pubErr) then
      return nil, pubErr
    end
    error(pubErr, 0)
  end
  return result
end

return RomExtractor
