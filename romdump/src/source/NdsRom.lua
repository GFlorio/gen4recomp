-- Parses and validates a Nintendo DS cartridge container (header, FAT, FNT,
-- overlay tables) over a RomSource. Does not write files; RomExtractor consumes
-- the parsed map. Full SHA-1 is authoritative for version identity and is
-- computed before any cache mutation elsewhere.
--
-- Only this module, RomSource, and RomExtractor may hold the full ROM. open()
-- returns (ndsRom | nil, err); malformed containers yield a structured Errors.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroFs = require("romdump.src.source.NitroFs")
local OverlayTable = require("romdump.src.source.OverlayTable")
local GameVersion = require("romdump.src.source.GameVersion")

local NdsRom = {}
NdsRom.__index = NdsRom

local MIN_HEADER = 0x200

local function parseHeader(reader)
  local function region(off)
    return { offset = reader:u32le(off), size = reader:u32le(off + 4) }
  end
  return {
    title = reader:ascii(0x00, 12, true),
    gameCode = reader:ascii(0x0C, 4),
    makerCode = reader:ascii(0x10, 2),
    unitCode = reader:u8(0x12),
    deviceCapacity = reader:u8(0x14),
    romVersion = reader:u8(0x1E),
    flags = reader:u8(0x1F),
    arm9 = {
      offset = reader:u32le(0x20),
      entryAddress = reader:u32le(0x24),
      ramAddress = reader:u32le(0x28),
      size = reader:u32le(0x2C),
    },
    arm7 = {
      offset = reader:u32le(0x30),
      entryAddress = reader:u32le(0x34),
      ramAddress = reader:u32le(0x38),
      size = reader:u32le(0x3C),
    },
    fnt = region(0x40),
    fat = region(0x48),
    arm9Overlays = region(0x50),
    arm7Overlays = region(0x58),
    bannerOffset = reader:u32le(0x68),
    usedRomSize = reader:u32le(0x80),
    headerSize = reader:u32le(0x84),
  }
end

local function assertInRomSize(name, offset, size, romSize)
  if offset < 0 or size < 0 or offset + size > romSize then
    Errors.raise(
      "NDS_SECTION_OUT_OF_RANGE",
      name .. " region (offset " .. offset .. ", size " .. size .. ") exceeds ROM of " .. romSize,
      { section = name, offset = offset, size = size, romSize = romSize }
    )
  end
end

local function readOrRaise(source, offset, length, name)
  local bytes, err = source:read(offset, length)
  if not bytes then
    Errors.raise("NDS_READ_FAILED", name .. ": " .. Errors.format(err), { section = name })
  end
  return bytes
end

local function parseFat(source, fatOffset, fatSize, romSize)
  local bytes = readOrRaise(source, fatOffset, fatSize, "fat")
  local reader = BinaryReader.new(bytes, "fat")
  local count = fatSize / 8
  local fat = {}
  for fileId = 0, count - 1 do
    local base = fileId * 8
    local startOffset = reader:u32le(base)
    local endOffset = reader:u32le(base + 4)
    if startOffset > endOffset then
      Errors.raise(
        "FAT_ENTRY_INVALID",
        "FAT entry " .. fileId .. " has start past end",
        { fileId = fileId, startOffset = startOffset, endOffset = endOffset }
      )
    end
    if endOffset > romSize then
      Errors.raise(
        "FAT_RANGE_OUT_OF_BOUNDS",
        "FAT entry " .. fileId .. " ends past the ROM",
        { fileId = fileId, startOffset = startOffset, endOffset = endOffset, romSize = romSize }
      )
    end
    fat[fileId] = { startOffset = startOffset, endOffset = endOffset, size = endOffset - startOffset }
  end
  return fat, count
end

function NdsRom._parse(source, versions)
  local romSize = source:size()
  if romSize < MIN_HEADER then
    Errors.raise("NDS_TOO_SMALL", "ROM is " .. romSize .. " bytes, need at least " .. MIN_HEADER, { size = romSize })
  end

  local header = parseHeader(BinaryReader.new(readOrRaise(source, 0, MIN_HEADER, "header"), "header"))

  -- Friendly early size check when the game code is recognized. Not a
  -- substitute for SHA-1, which is authoritative.
  local byCode = versions.forGameCode(header.gameCode)
  if byCode and byCode.expectedSize and byCode.expectedSize ~= romSize then
    Errors.raise(
      "NDS_SIZE_MISMATCH",
      "ROM size " .. romSize .. " does not match expected " .. byCode.expectedSize .. " for " .. header.gameCode,
      { size = romSize, expectedSize = byCode.expectedSize, gameCode = header.gameCode }
    )
  end

  local sha1 = source:sha1()
  local versionInfo = versions.forSha1(sha1)
  if not versionInfo then
    Errors.raise(
      "NDS_UNKNOWN_ROM",
      "no supported version matches SHA-1 " .. sha1 .. " (patched, modified, overdumped, or unsupported)",
      { sha1 = sha1, gameCode = header.gameCode }
    )
  end
  if versionInfo.gameCode ~= header.gameCode then
    Errors.raise(
      "NDS_GAME_CODE_MISMATCH",
      "header game code " .. header.gameCode .. " does not match " .. versionInfo.gameCode .. " for the matched version",
      { headerGameCode = header.gameCode, versionGameCode = versionInfo.gameCode, sha1 = sha1 }
    )
  end

  assertInRomSize("arm9", header.arm9.offset, header.arm9.size, romSize)
  assertInRomSize("arm7", header.arm7.offset, header.arm7.size, romSize)
  assertInRomSize("fnt", header.fnt.offset, header.fnt.size, romSize)
  assertInRomSize("fat", header.fat.offset, header.fat.size, romSize)
  assertInRomSize("arm9Overlays", header.arm9Overlays.offset, header.arm9Overlays.size, romSize)
  assertInRomSize("arm7Overlays", header.arm7Overlays.offset, header.arm7Overlays.size, romSize)

  if header.fat.size == 0 or header.fat.size % 8 ~= 0 then
    Errors.raise(
      "NDS_FAT_SIZE_INVALID",
      "FAT size " .. header.fat.size .. " must be nonzero and divisible by 8",
      { fatSize = header.fat.size }
    )
  end

  local fat, fatCount = parseFat(source, header.fat.offset, header.fat.size, romSize)
  local nitro = NitroFs.parse(readOrRaise(source, header.fnt.offset, header.fnt.size, "fnt"), fatCount)
  local arm9Overlays = OverlayTable.parse(
    readOrRaise(source, header.arm9Overlays.offset, header.arm9Overlays.size, "arm9Overlays"),
    fatCount,
    "arm9"
  )
  local arm7Overlays = OverlayTable.parse(
    readOrRaise(source, header.arm7Overlays.offset, header.arm7Overlays.size, "arm7Overlays"),
    fatCount,
    "arm7"
  )

  return setmetatable({
    _source = source,
    _versionInfo = versionInfo,
    _header = header,
    _fat = fat,
    _fatCount = fatCount,
    _nitro = nitro,
    _arm9Overlays = arm9Overlays,
    _arm7Overlays = arm7Overlays,
  }, NdsRom)
end

function NdsRom.open(source, versions)
  versions = versions or GameVersion
  local ok, result = pcall(NdsRom._parse, source, versions)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function NdsRom:size()
  return self._source:size()
end
function NdsRom:header()
  return self._header
end
function NdsRom:nitroFs()
  return self._nitro
end
function NdsRom:arm9Overlays()
  return self._arm9Overlays
end
function NdsRom:arm7Overlays()
  return self._arm7Overlays
end
function NdsRom:fatCount()
  return self._fatCount
end
function NdsRom:versionInfo()
  return self._versionInfo
end

function NdsRom:read(offset, length)
  return self._source:read(offset, length)
end

function NdsRom:readFatFile(fileId)
  local entry = self._fat[fileId]
  if not entry then
    Errors.raise(
      "NDS_FILE_ID_OUT_OF_RANGE",
      "no FAT entry for fileId " .. tostring(fileId),
      { fileId = fileId, fatCount = self._fatCount }
    )
  end
  return readOrRaise(self._source, entry.startOffset, entry.size, "fat file " .. fileId)
end

-- Assign exactly one cache destination to every FAT entry, in the priority
-- order FNT name > arm9 overlay > arm7 overlay > unmapped.
function NdsRom:fileMap()
  local overlayByFileId = {}
  for _, ov in ipairs(self._arm9Overlays) do
    overlayByFileId[ov.fileId] = { kind = "overlay9", overlayId = ov.overlayId }
  end
  for _, ov in ipairs(self._arm7Overlays) do
    overlayByFileId[ov.fileId] = { kind = "overlay7", overlayId = ov.overlayId }
  end

  local named = self._nitro.byFileId
  local map, seen = {}, {}
  for fileId = 0, self._fatCount - 1 do
    local entry = self._fat[fileId]
    local dest = { fileId = fileId, offset = entry.startOffset, size = entry.size }
    local sourcePath = named[fileId]
    local overlay = overlayByFileId[fileId]
    if sourcePath then
      dest.kind = "nitrofs"
      dest.sourcePath = sourcePath
      dest.path = "romfs/" .. sourcePath
    elseif overlay then
      dest.kind = overlay.kind
      dest.overlayId = overlay.overlayId
      dest.path = "system/" .. overlay.kind .. "/overlay_" .. overlay.overlayId .. ".bin"
    else
      dest.kind = "unmapped"
      dest.path = "system/unmapped/file_" .. fileId .. ".bin"
    end
    assert(not seen[dest.path], "duplicate cache destination: " .. dest.path)
    seen[dest.path] = true
    map[fileId] = dest
  end
  return map
end

function NdsRom:release()
  self._source:release()
end

return NdsRom
