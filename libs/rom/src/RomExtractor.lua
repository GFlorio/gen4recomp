-- Materializes a parsed NdsRom into the private per-version cache: a lossless
-- raw NitroFS dump plus deterministic generated metadata, finished by a
-- marker-last transaction. Orchestration only; all binary parsing
-- lives in the pure modules it drives. run() wraps a private pipeline in pcall
-- and returns (report | nil, err); the completion marker is written only after
-- every other output and the final recheck succeed.
--
-- This module is allowed to hold the full ROM (via NdsRom); releasing it is the
-- caller's responsibility. Responsiveness/yielding belongs to the
-- importer coroutine that drives the progress callback, not here.

local Errors = require("libs.rom.src.Errors")
local Narc = require("libs.rom.src.Narc")
local MapMatrix = require("romdump.src.digest.MapMatrix")

local RomExtractor = {}
RomExtractor.__index = RomExtractor

-- Raw-dump cache format. Independent of any future decoded-data format; bump
-- only when the dump layout or romfs_index schema changes.
RomExtractor.DUMP_FORMAT = 1
local MARKER_PATH = "rom-dump.complete"

function RomExtractor.markerContent(versionId, sha1)
  return "g4-rom-dump-v" .. RomExtractor.DUMP_FORMAT .. ":" .. versionId .. ":" .. sha1
end

-- Ordered stages with the [start, finish) fraction each occupies of the overall
-- progress bar. Monotonic by construction.
local STAGES = {
  { key = "prepare",               label = "Preparing cache",       from = 0.00, to = 0.02 },
  { key = "write_system_metadata", label = "Writing system data",   from = 0.02, to = 0.10 },
  { key = "dump_files",            label = "Dumping NitroFS",       from = 0.10, to = 0.80 },
  { key = "write_indexes",         label = "Writing indexes",       from = 0.80, to = 0.88 },
  { key = "validate_narcs",        label = "Validating NARCs",      from = 0.88, to = 0.94 },
  { key = "smoke_decode",          label = "Decoding map matrix",   from = 0.94, to = 0.97 },
  { key = "finalize",              label = "Finalizing",            from = 0.97, to = 1.00 },
}
local STAGE_BY_KEY = {}
for _, s in ipairs(STAGES) do STAGE_BY_KEY[s.key] = s end

function RomExtractor.new(ndsRom, versionInfo, cache, manifest, progressCallback)
  assert(ndsRom and versionInfo and cache and manifest, "RomExtractor.new requires ndsRom, versionInfo, cache, manifest")
  return setmetatable({
    _rom = ndsRom,
    _version = versionInfo,
    _cache = cache,
    _manifest = manifest,
    _progress = progressCallback,
  }, RomExtractor)
end

function RomExtractor:_emit(stageKey, current, total, detail)
  if not self._progress then return end
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
    Errors.raise("EXTRACT_READ_FAILED", name .. ": " .. Errors.format(err), { section = name })
  end
  return bytes
end

-- Stage 1: remove the marker first, then wipe this version's stale partial
-- output, then recreate the output directories.
function RomExtractor:_prepare()
  self._cache:remove(MARKER_PATH)
  self._cache:removeTree("")
  for _, dir in ipairs({
    "data/generated", "romfs", "system",
    "system/overlay9", "system/overlay7", "system/unmapped",
  }) do
    self._cache:createDirectory(dir)
  end
  self:_emit("prepare", 1, 1)
end

-- Stage 2: raw header, FNT, FAT, overlay tables, and ARM binaries.
function RomExtractor:_writeSystemMetadata()
  local rom, h = self._rom, self._rom:header()
  self._cache:write("system/header.bin", readRom(rom, 0, 0x200, "header"))
  self._cache:write("system/fnt.bin", readRom(rom, h.fnt.offset, h.fnt.size, "fnt"))
  self._cache:write("system/fat.bin", readRom(rom, h.fat.offset, h.fat.size, "fat"))
  self._cache:write("system/arm9_overlay_table.bin",
    readRom(rom, h.arm9Overlays.offset, h.arm9Overlays.size, "arm9_overlay_table"))
  self._cache:write("system/arm7_overlay_table.bin",
    readRom(rom, h.arm7Overlays.offset, h.arm7Overlays.size, "arm7_overlay_table"))
  self._cache:write("system/arm9.bin", readRom(rom, h.arm9.offset, h.arm9.size, "arm9"))
  self._cache:write("system/arm7.bin", readRom(rom, h.arm7.offset, h.arm7.size, "arm7"))
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
    self._cache:write(dest.path, data)
    local info = self._cache:getInfo(dest.path)
    if not info or info.size ~= dest.size then
      Errors.raise("EXTRACT_WRITE_SIZE_MISMATCH",
        "wrote " .. tostring(info and info.size) .. " bytes to " .. dest.path
          .. ", expected " .. dest.size,
        { path = dest.path, fileId = fileId, expected = dest.size,
          actual = info and info.size })
    end
    totalBytes = totalBytes + dest.size
    if dest.kind == "unmapped" then unmapped = unmapped + 1 end
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

  self._cache:writeLua("data/generated/rom_metadata.lua", {
    schema = 1,
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
    arm9 = { offset = h.arm9.offset, size = h.arm9.size,
      entryAddress = h.arm9.entryAddress, ramAddress = h.arm9.ramAddress },
    arm7 = { offset = h.arm7.offset, size = h.arm7.size,
      entryAddress = h.arm7.entryAddress, ramAddress = h.arm7.ramAddress },
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
  self._cache:writeLua("data/generated/romfs_index.lua", {
    schema = 1,
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
  self._cache:writeLua("data/generated/overlay_index.lua", {
    schema = 1,
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
        Errors.raise("EXTRACT_REQUIRED_NARC_MISSING",
          "required NARC " .. entry.symbol .. " path " .. entry.path .. " not in FNT",
          { symbol = entry.symbol, path = entry.path })
      end
      warnings[#warnings + 1] = "unresolved optional NARC " .. entry.symbol .. " (" .. entry.path .. ")"
    else
      local narc, err = Narc.open(self._rom:readFatFile(fileId), entry.path)
      if not narc then
        if entry.required then
          Errors.raise("EXTRACT_REQUIRED_NARC_INVALID",
            "required NARC " .. entry.symbol .. " (" .. entry.path .. ") failed to open: "
              .. Errors.format(err),
            { symbol = entry.symbol, path = entry.path, fileId = fileId })
        end
        warnings[#warnings + 1] = "non-NARC optional entry " .. entry.symbol .. " (" .. entry.path .. ")"
      else
        opened[entry.alias] = narc
        if entry.required then requiredCount = requiredCount + 1 end
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
    Errors.raise("EXTRACT_SMOKE_READ_FAILED",
      "map_matrices member 0: " .. Errors.format(err), {})
  end
  local matrix, decodeErr = MapMatrix.decode(member, 0)
  if not matrix then
    Errors.raise("EXTRACT_SMOKE_DECODE_FAILED",
      "map_matrices member 0 did not decode: " .. Errors.format(decodeErr), {})
  end
  self:_emit("smoke_decode", 1, 1)
  return {
    name = matrix.name,
    width = matrix.width,
    height = matrix.height,
    modelCellCount = matrix.width * matrix.height,
  }
end

-- Stage 7: write import_report, recheck the required outputs, then write the
-- marker last.
function RomExtractor:_finalize(report)
  self._cache:writeLua("data/generated/import_report.lua", report)

  for _, path in ipairs({
    "data/generated/rom_metadata.lua",
    "data/generated/romfs_index.lua",
    "data/generated/overlay_index.lua",
  }) do
    if not self._cache:exists(path, "file") then
      Errors.raise("EXTRACT_OUTPUT_MISSING", "required output missing at finalize: " .. path,
        { path = path })
    end
  end

  self._cache:write(MARKER_PATH, RomExtractor.markerContent(self._version.id, self._version.sha1))
  self:_emit("finalize", 1, 1)
end

function RomExtractor:_run()
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
    parserWarnings = {},
    matrix = matrix,
  }
  self:_finalize(report)
  return report
end

function RomExtractor:run()
  local ok, result = pcall(self._run, self)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return RomExtractor
