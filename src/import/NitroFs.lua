-- Recursive NitroFS FNT parser. Pure domain module: turns the raw FNT byte
-- region into exact source paths keyed by zero-based fileId, plus the reverse
-- map. Malformed tables raise structured Errors rather than reading past the
-- supplied bytes. Directory ids are 0xF000-based; the low 12 bits
-- select the directory record.

local Errors = require("src.import.Errors")
local BinaryReader = require("src.import.BinaryReader")

local NitroFs = {}

local DIR_ID_BASE = 0xF000
local DIR_RECORD_SIZE = 8

local function validName(name)
  if #name == 0 then return false end
  if name == "." or name == ".." then return false end
  return name:find("[/\\%z]") == nil
end

local function readDirRecord(reader, index)
  local base = index * DIR_RECORD_SIZE
  return {
    subtableOffset = reader:u32le(base),
    firstFileId = reader:u16le(base + 4),
    field = reader:u16le(base + 6),
  }
end

function NitroFs.parse(fntBytes, fatCount)
  assert(type(fntBytes) == "string", "FNT bytes must be a string")
  assert(type(fatCount) == "number", "fatCount must be a number")
  local reader = BinaryReader.new(fntBytes, "fnt")

  local root = readDirRecord(reader, 0)
  local dirCount = root.field
  if dirCount < 1 or dirCount > 4096 then
    Errors.raise("FNT_DIR_COUNT_INVALID",
      "directory count " .. dirCount .. " outside 1..4096",
      { dirCount = dirCount })
  end
  reader:assertRange(0, dirCount * DIR_RECORD_SIZE, "fnt main table")

  local byFileId, byPath, directories = {}, {}, {}
  local namedFileCount = 0
  local visited = {}

  local function walk(dirId, parentPath)
    local recordIndex = dirId - DIR_ID_BASE
    if recordIndex < 0 or recordIndex >= dirCount then
      Errors.raise("FNT_DIR_ID_OUT_OF_RANGE",
        "directory id " .. string.format("0x%X", dirId) .. " outside table",
        { dirId = dirId, dirCount = dirCount })
    end
    if visited[dirId] then
      Errors.raise("FNT_DIRECTORY_CYCLE",
        "directory " .. string.format("0x%X", dirId) .. " visited twice",
        { dirId = dirId })
    end
    visited[dirId] = true

    local record = readDirRecord(reader, recordIndex)
    directories[#directories + 1] =
      { dirId = dirId, path = parentPath, firstFileId = record.firstFileId }

    local cursor = record.subtableOffset
    local fileId = record.firstFileId
    while true do
      local typeByte = reader:u8(cursor)
      cursor = cursor + 1
      if typeByte == 0 then break end
      local nameLen = typeByte % 0x80
      local isDir = typeByte >= 0x80
      local name = reader:ascii(cursor, nameLen)
      cursor = cursor + nameLen
      if not validName(name) then
        Errors.raise("FNT_INVALID_NAME", "invalid entry name " .. string.format("%q", name),
          { name = name, dirId = dirId })
      end
      local fullPath = parentPath .. name
      if isDir then
        local childId = reader:u16le(cursor)
        cursor = cursor + 2
        walk(childId, fullPath .. "/")
      else
        if fileId >= fatCount then
          Errors.raise("FNT_FILE_ID_OUT_OF_FAT",
            "named file id " .. fileId .. " outside FAT of " .. fatCount,
            { fileId = fileId, fatCount = fatCount, path = fullPath })
        end
        if byPath[fullPath] ~= nil then
          Errors.raise("FNT_DUPLICATE_PATH", "duplicate path " .. fullPath, { path = fullPath })
        end
        if byFileId[fileId] ~= nil then
          Errors.raise("FNT_DUPLICATE_FILE_ID", "file id " .. fileId .. " assigned twice",
            { fileId = fileId, path = fullPath, existing = byFileId[fileId] })
        end
        byFileId[fileId] = fullPath
        byPath[fullPath] = fileId
        namedFileCount = namedFileCount + 1
        fileId = fileId + 1
      end
    end
  end

  walk(DIR_ID_BASE, "")

  return {
    byFileId = byFileId,
    byPath = byPath,
    directories = directories,
    namedFileCount = namedFileCount,
  }
end

return NitroFs
