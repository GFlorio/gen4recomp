-- The only runtime entry point for the raw ROM dump (spec §16). It loads the
-- generated metadata through CacheFs, validates schemas, and serves file bytes
-- and NARC members lazily by FAT fileId, exact NitroFS source path, or curated
-- alias/symbol. It never re-reads the original ROM and never caches large
-- payloads globally.
--
-- Transient maps (source path -> fileId, alias/symbol -> resolved NARC) are
-- built once at open() from the on-disk index; the generated files deliberately
-- do not duplicate them. Decoders should prefer explicit readSourcePath.

local Errors = require("src.import.Errors")
local CacheFs = require("src.import.CacheFs")
local Narc = require("src.import.Narc")
local RomImporter = require("src.import.RomImporter")
local Hgss = require("data.manifests.hgss")

local RomFs = {}
RomFs.__index = RomFs

local function loadRequired(cache, path)
  local value, err = cache:loadLua(path)
  if not value then
    Errors.raise("ROMFS_LOAD_FAILED", "could not load " .. path .. ": " .. Errors.format(err),
      { path = path })
  end
  return value
end

local function requireSchema(value, expected, name)
  if value.schema ~= expected then
    Errors.raise("ROMFS_SCHEMA_MISMATCH",
      name .. " schema " .. tostring(value.schema) .. " ~= expected " .. expected,
      { name = name, schema = value.schema, expected = expected })
  end
end

local function _open(versionId, cache)
  cache = cache or CacheFs.forVersion(versionId)
  if not RomImporter.isReady(versionId, cache) then
    Errors.raise("ROMFS_NOT_READY",
      "no ready dump for version " .. tostring(versionId), { version = versionId })
  end

  local metadata = loadRequired(cache, "data/generated/rom_metadata.lua")
  local index = loadRequired(cache, "data/generated/romfs_index.lua")
  local resolved = loadRequired(cache, "data/generated/resolved_narcs.lua")
  requireSchema(metadata, 1, "rom_metadata")
  requireSchema(index, 1, "romfs_index")
  requireSchema(resolved, 1, "resolved_narcs")

  -- Build transient lookups once (spec §7.2 forbids duplicating them on disk).
  local byPath, bySymbol, byAlias = {}, {}, {}
  for fileId = 0, index.fileCount - 1 do
    local entry = index.files[fileId]
    assert(entry, "romfs_index missing fileId " .. fileId)
    if entry.sourcePath then byPath[entry.sourcePath] = fileId end
  end
  local resolvedCount = 0
  for symbol, entry in pairs(resolved.entries) do
    bySymbol[symbol] = entry
    byAlias[entry.alias] = entry
    resolvedCount = resolvedCount + 1
  end

  return setmetatable({
    _version = versionId,
    _cache = cache,
    _metadata = metadata,
    _index = index,
    _byPath = byPath,
    _bySymbol = bySymbol,
    _byAlias = byAlias,
    _resolvedCount = resolvedCount,
  }, RomFs)
end

function RomFs.open(versionId, cache)
  local ok, result = pcall(_open, versionId, cache)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

function RomFs:version() return self._version end
function RomFs:metadata() return self._metadata end
function RomFs:fileCount() return self._index.fileCount end

-- Aggregate counts for diagnostics, drawn straight from the loaded index.
function RomFs:stats()
  local i = self._index
  return {
    fileCount = i.fileCount,
    namedFileCount = i.namedFileCount,
    overlayFileCount = i.overlayFileCount,
    unmappedFileCount = i.unmappedFileCount,
    totalFileBytes = i.totalFileBytes,
    resolvedNarcCount = self._resolvedCount,
  }
end

-- Resolve a fileId or an exact NitroFS source path to its index entry.
function RomFs:info(pathOrFileId)
  local fileId = pathOrFileId
  if type(pathOrFileId) == "string" then
    fileId = self._byPath[pathOrFileId]
    if not fileId then
      return nil, Errors.new("ROMFS_PATH_UNKNOWN", "no NitroFS file at " .. pathOrFileId,
        { sourcePath = pathOrFileId })
    end
  end
  local entry = self._index.files[fileId]
  if not entry then
    return nil, Errors.new("ROMFS_FILE_ID_UNKNOWN", "no file for fileId " .. tostring(fileId),
      { fileId = fileId })
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
  if not entry then return nil, err end
  local data = self._cache:read(entry.path)
  if data == nil then
    return nil, Errors.new("ROMFS_FILE_MISSING", "dump file missing: " .. entry.path,
      { path = entry.path })
  end
  return data
end

function RomFs:readSourcePath(sourcePath)
  assert(type(sourcePath) == "string", "readSourcePath requires a string")
  return self:read(sourcePath)
end

-- Resolve a curated alias, version-neutral alias, or raw NARC symbol to its
-- resolved entry (with the FNT-derived fileId and memberCount).
function RomFs:resolvedNarc(symbolOrAlias)
  local entry = self._bySymbol[symbolOrAlias] or self._byAlias[symbolOrAlias]
  if entry then return entry end
  local ok, manifestEntry = pcall(Hgss.resolve, symbolOrAlias, self._version)
  if ok and manifestEntry then return self._bySymbol[manifestEntry.symbol] end
  return nil
end

function RomFs:openNarc(symbolOrAlias)
  local entry = self:resolvedNarc(symbolOrAlias)
  if not entry then
    return nil, Errors.new("ROMFS_NARC_UNRESOLVED", "no resolved NARC for " .. tostring(symbolOrAlias),
      { name = symbolOrAlias })
  end
  local data, err = self:read(entry.fileId)
  if not data then return nil, err end
  return Narc.open(data, entry.path)
end

function RomFs:close()
  self._cache = nil
  self._metadata = nil
  self._index = nil
  self._byPath = nil
  self._bySymbol = nil
  self._byAlias = nil
end

return RomFs
