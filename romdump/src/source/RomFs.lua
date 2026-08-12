-- The only runtime entry point for the raw ROM dump. It loads the
-- generated metadata through CacheFs, validates schemas, and serves file bytes
-- and NARC members lazily by FAT fileId, exact NitroFS source path, or curated
-- alias/symbol. It never re-reads the original ROM and never caches large
-- payloads globally.
--
-- Transient maps (source path -> fileId, alias/symbol -> resolved NARC) are
-- built once at open() from the on-disk index; the generated files deliberately
-- do not duplicate them. Decoders should prefer explicit readSourcePath.

local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local Narc = require("romdump.src.source.Narc")
local RomImporter = require("romdump.src.source.RomImporter")
local OverlayCompression = require("romdump.src.source.OverlayCompression")
local HgssArchives = require("romdump.src.config.HgssArchives")

---@class RomFs
---@field private _version string
---@field private _metadata table
local RomFs = {}
RomFs.__index = RomFs

---@class RomFs.Narc
---@field readMember fun(self: RomFs.Narc, memberId: integer): string?, Errors.Error?
---@field memberCount fun(self: RomFs.Narc): integer
---@field memberInfo fun(self: RomFs.Narc, memberId: integer): table?, Errors.Error?

---@class RomFs.NarcInfo
---@field symbol string
---@field alias string
---@field narcId integer
---@field path string
---@field fileId integer

local function loadRequired(cache, path)
  local value, err = cache:loadLua(path)
  if not value then
    Errors.raise("ROMFS_LOAD_FAILED", "could not load " .. path .. ": " .. Errors.format(err), { path = path })
  end
  return value
end

local function requireSchema(value, expected, name)
  if value.schema ~= expected then
    Errors.raise(
      "ROMFS_SCHEMA_MISMATCH",
      name .. " schema " .. tostring(value.schema) .. " ~= expected " .. expected,
      { name = name, schema = value.schema, expected = expected }
    )
  end
end

local function _open(versionId, cache)
  cache = cache or CacheFs.forVersion(versionId)
  if not RomImporter.isReady(versionId, cache) then
    Errors.raise("ROMFS_NOT_READY", "no ready dump for version " .. tostring(versionId), { version = versionId })
  end

  local metadata = loadRequired(cache, "data/generated/rom_metadata.lua")
  local index = loadRequired(cache, "data/generated/romfs_index.lua")
  local overlayIndex = loadRequired(cache, "data/generated/overlay_index.lua")
  requireSchema(metadata, 1, "rom_metadata")
  requireSchema(index, 1, "romfs_index")
  if overlayIndex.schema ~= 1 or type(overlayIndex.arm9) ~= "table" or type(overlayIndex.arm7) ~= "table" then
    Errors.raise(
      "ROMFS_OVERLAY_INDEX_SCHEMA",
      "overlay_index must use schema 1 with arm9 and arm7 tables",
      { schema = overlayIndex.schema }
    )
  end

  -- Build the source-path -> fileId lookup once from the FNT index. NARC alias
  -- resolution is derived on demand from the checked-in manifest plus this
  -- lookup, so there is no baked alias table to persist or keep in sync.
  local byPath = {}
  for fileId = 0, index.fileCount - 1 do
    local entry = index.files[fileId]
    assert(entry, "romfs_index missing fileId " .. fileId)
    if entry.sourcePath then
      byPath[entry.sourcePath] = fileId
    end
  end

  return setmetatable({
    _version = versionId,
    _cache = cache,
    _metadata = metadata,
    _index = index,
    _overlayIndex = overlayIndex,
    _byPath = byPath,
  }, RomFs)
end

function RomFs.open(versionId, cache)
  local ok, result = pcall(_open, versionId, cache)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function RomFs:version()
  return self._version
end
function RomFs:metadata()
  return self._metadata
end
function RomFs:fileCount()
  return self._index.fileCount
end

-- Count curated aliases that resolve against this dump's FNT (i.e. whose path
-- is present). Derived, not stored, so it always reflects the current manifest.
function RomFs:_resolvedNarcCount()
  local count = 0
  for _, entry in ipairs(HgssArchives.aliasList()) do
    if self._byPath[entry.path] then
      count = count + 1
    end
  end
  return count
end

-- Aggregate counts for diagnostics, drawn straight from the loaded index.
function RomFs:stats()
  local i = self._index
  return {
    fileCount = i.fileCount,
    namedFileCount = i.namedFileCount,
    overlayFileCount = i.overlayFileCount,
    unmappedFileCount = i.unmappedFileCount,
    totalFileBytes = i.totalFileBytes,
    resolvedNarcCount = self:_resolvedNarcCount(),
  }
end

-- Resolve a fileId or an exact NitroFS source path to its index entry.
function RomFs:info(pathOrFileId)
  local fileId = pathOrFileId
  if type(pathOrFileId) == "string" then
    fileId = self._byPath[pathOrFileId]
    if not fileId then
      return nil, Errors.new("ROMFS_PATH_UNKNOWN", "no NitroFS file at " .. pathOrFileId, { sourcePath = pathOrFileId })
    end
  end
  local entry = self._index.files[fileId]
  if not entry then
    return nil, Errors.new("ROMFS_FILE_ID_UNKNOWN", "no file for fileId " .. tostring(fileId), { fileId = fileId })
  end
  return entry
end

function RomFs:pathForFileId(fileId)
  local entry = self._index.files[fileId]
  return entry and entry.path or nil
end

function RomFs:fileIdForPath(sourcePath)
  return self._byPath[sourcePath]
end

-- Read a FAT-backed file by fileId or by exact source path.
function RomFs:read(pathOrFileId)
  local entry, err = self:info(pathOrFileId)
  if not entry then
    return nil, err
  end
  local data = self._cache:read(entry.path)
  if data == nil then
    return nil, Errors.new("ROMFS_FILE_MISSING", "dump file missing: " .. entry.path, { path = entry.path })
  end
  return data
end

function RomFs:readSourcePath(sourcePath)
  assert(type(sourcePath) == "string", "readSourcePath requires a string")
  return self:read(sourcePath)
end

-- Resolve an imported ARM overlay by its CPU and zero-based overlayId. Overlay
-- metadata comes from the generated overlay table; bytes still flow through
-- the ordinary FAT-backed file index.
function RomFs:overlayInfo(cpu, overlayId)
  if cpu ~= "arm9" and cpu ~= "arm7" then
    return nil,
      Errors.new(
        "ROMFS_OVERLAY_UNKNOWN_CPU",
        "unknown overlay CPU " .. tostring(cpu),
        { cpu = cpu, overlayId = overlayId }
      )
  end
  local raw = self._overlayIndex[cpu][overlayId]
  if not raw then
    return nil,
      Errors.new(
        "ROMFS_OVERLAY_UNKNOWN_ID",
        "no " .. cpu .. " overlay for overlayId " .. tostring(overlayId),
        { cpu = cpu, overlayId = overlayId }
      )
  end
  local file = self._index.files[raw.fileId]
  assert(file, "overlay_index references missing fileId " .. tostring(raw.fileId))
  return {
    cpu = cpu,
    overlayId = raw.overlayId,
    fileId = raw.fileId,
    path = file.path,
    ramAddress = raw.ramAddress,
    ramSize = raw.ramSize,
    bssSize = raw.bssSize,
    staticInitStart = raw.staticInitStart,
    staticInitEnd = raw.staticInitEnd,
    flags = raw.flags,
    compressedSize = raw.flags % 16777216,
    isCompressed = math.floor(raw.flags / 16777216) % 2 == 1,
  }
end

function RomFs:readOverlay(cpu, overlayId)
  local info, err = self:overlayInfo(cpu, overlayId)
  if not info then
    return nil, err
  end
  local bytes, readErr = self:read(info.fileId)
  if not bytes then
    return nil,
      Errors.new(
        "ROMFS_OVERLAY_FILE_MISSING",
        "dumped overlay file is missing: " .. info.path,
        { cpu = cpu, overlayId = overlayId, fileId = info.fileId, path = info.path, cause = readErr and readErr.code }
      )
  end
  if info.isCompressed then
    local decoded, decodeErr = OverlayCompression.decode(bytes, info.ramSize)
    if not decoded then
      return nil, decodeErr
    end
    bytes = decoded
  end
  return bytes, info
end

-- Resolve a curated alias, version-neutral alias, or raw NARC symbol to a fileId
-- entry, using the checked-in manifest plus this dump's FNT path index. Returns
-- nil if the manifest does not know the name or its path is absent from the FNT.
-- No memberCount is included (that requires opening the NARC); openNarc does
-- not need it.
function RomFs:resolvedNarc(symbolOrAlias)
  local ok, entry = pcall(HgssArchives.resolve, symbolOrAlias, self._version)
  if not (ok and entry) then
    return nil
  end
  local fileId = self._byPath[entry.path]
  if not fileId then
    return nil
  end
  return {
    symbol = entry.symbol,
    alias = entry.alias,
    narcId = entry.narcId,
    path = entry.path,
    fileId = fileId,
  }
end

function RomFs:openNarc(symbolOrAlias)
  local entry = self:resolvedNarc(symbolOrAlias)
  if not entry then
    return nil,
      Errors.new("ROMFS_NARC_UNRESOLVED", "no resolved NARC for " .. tostring(symbolOrAlias), { name = symbolOrAlias })
  end
  local data, err = self:read(entry.fileId)
  if not data then
    return nil, err
  end
  return Narc.open(data, entry.path)
end

function RomFs:close()
  self._cache = nil
  self._metadata = nil
  self._index = nil
  self._overlayIndex = nil
  self._byPath = nil
end

return RomFs
