-- Owns the original ROM bytes and hides how they were obtained. Only this
-- module, NdsRom, and RomExtractor may hold the full ROM string. The canonical
-- ROM is 128 MiB and kept as one Lua string in v1 (not a byte table); a
-- streaming backend can replace this later without changing callers.
--
-- Infrastructure module: fromPath uses io (arbitrary absolute paths are outside
-- love.filesystem's sandbox) and sha1 uses love.data.hash.

local Errors = require("src.import.Errors")

local RomSource = {}
RomSource.__index = RomSource

local function toHex(bin)
  local out = {}
  for i = 1, #bin do out[i] = string.format("%02x", bin:byte(i)) end
  return table.concat(out)
end

local function basename(path)
  return (path:gsub("\\", "/"):match("([^/]+)$")) or path
end

function RomSource.fromString(data, displayName)
  assert(type(data) == "string", "RomSource requires string data")
  return setmetatable({ data = data, name = displayName or "rom", _sha1 = nil }, RomSource)
end

function RomSource.fromPath(path)
  local file, ioErr = io.open(path, "rb")
  if not file then
    return nil, Errors.new("ROM_OPEN_FAILED", ioErr or "could not open file", { path = path })
  end
  local data = file:read("*a")
  file:close()
  if not data then
    return nil, Errors.new("ROM_READ_FAILED", "could not read file", { path = path })
  end
  return RomSource.fromString(data, basename(path))
end

function RomSource.fromDroppedFile(droppedFile)
  assert(droppedFile, "dropped file is required")
  local ok, openErr = droppedFile:open("r")
  if not ok then
    return nil, Errors.new("ROM_OPEN_FAILED", tostring(openErr), { name = droppedFile:getFilename() })
  end
  local data = droppedFile:read()
  droppedFile:close()
  return RomSource.fromString(data, basename(droppedFile:getFilename()))
end

function RomSource:size()
  return self.data and #self.data or self._size or 0
end

function RomSource:read(offset, length)
  if not self.data then
    return nil, Errors.new("ROM_RELEASED", "ROM source has been released", {})
  end
  if type(offset) ~= "number" or offset < 0
      or type(length) ~= "number" or length < 0
      or offset + length > #self.data then
    return nil, Errors.new("ROM_READ_OUT_OF_BOUNDS", "read outside ROM bounds",
      { offset = offset, length = length, size = #self.data })
  end
  return string.sub(self.data, offset + 1, offset + length)
end

function RomSource:sha1()
  if not self._sha1 then
    assert(self.data, "cannot hash a released ROM source")
    self._sha1 = toHex(love.data.hash("sha1", self.data))
  end
  return self._sha1
end

function RomSource:displayName()
  return self.name
end

function RomSource:release()
  if self.data then self._size = #self.data end
  self.data = nil
end

return RomSource
