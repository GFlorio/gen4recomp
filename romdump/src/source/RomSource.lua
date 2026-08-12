-- Owns the original ROM bytes and hides how they were obtained. Only this
-- module, NdsRom, and RomExtractor may hold the full ROM string. The canonical
-- ROM is 128 MiB and kept as one Lua string in v1 (not a byte table); a
-- streaming backend can replace this later without changing callers.
--
-- Infrastructure module: fromPath uses io (arbitrary absolute paths are outside
-- love.filesystem's sandbox) and sha1 uses love.data.hash.

local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")

local RomSource = {}
RomSource.__index = RomSource

local function toHex(bin)
  local out = {}
  for i = 1, #bin do
    out[i] = string.format("%02x", bin:byte(i))
  end
  return table.concat(out)
end

local function basename(path)
  return (path:gsub("\\", "/"):match("([^/]+)$")) or path
end

function RomSource.fromString(data, displayName)
  assert(type(data) == "string", "RomSource requires string data")
  return setmetatable({ data = data, name = displayName or "rom", _sha1 = nil }, RomSource)
end

local function isZip(name)
  return name:lower():match("%.zip$") ~= nil
end

-- Mount a zip in memory and locate one usable .nds entry. Candidates are
-- inspected one at a time: the first entry whose SHA-1 matches a supported
-- version wins; otherwise the first .nds is returned as a fallback so NdsRom
-- can report a precise unknown-ROM error. At most the current candidate and
-- one fallback candidate are retained at once, and the mount is always
-- unmounted, including when traversal raises.
--
-- love.filesystem.mount accepts FileData (11.0+), so arbitrary-path archives
-- never touch disk.
-- The mount point is exported at this owner boundary (the module that mounts);
-- the test suite references it to observe leaked mounts.
RomSource.MOUNT_POINT = "g4-romzip"

local function findNdsCandidate(zipBytes, zipName, versions)
  local fd = love.filesystem.newFileData(zipBytes, "romzip.zip")
  love.filesystem.unmount(fd) -- clear any stale mount from a prior import
  if not love.filesystem.mount(fd, RomSource.MOUNT_POINT) then
    return nil, Errors.new("ZIP_MOUNT_FAILED", "could not read zip: " .. zipName, { name = zipName })
  end

  local found
  local ok, walkErr = pcall(function()
    local fallback
    local function walk(dir)
      for _, item in ipairs(love.filesystem.getDirectoryItems(dir)) do
        if found then
          return
        end
        local full = dir .. "/" .. item
        local info = love.filesystem.getInfo(full)
        if info and info.type == "directory" then
          walk(full)
        elseif item:lower():match("%.nds$") then
          local bytes = love.filesystem.read(full)
          if not bytes then
            Errors.raise("ZIP_READ_FAILED", "could not read .nds entry: " .. full, { name = zipName, entry = full })
          end
          local candidate = RomSource.fromString(bytes, zipName .. ":" .. full:sub(#RomSource.MOUNT_POINT + 2))
          if versions.forSha1(candidate:sha1()) then
            if fallback then
              fallback:release()
            end
            found = candidate
          elseif fallback then
            candidate:release()
          else
            fallback = candidate
          end
        end
      end
    end
    walk(RomSource.MOUNT_POINT)
    found = found or fallback
  end)
  love.filesystem.unmount(fd)
  if not ok then
    if Errors.is(walkErr) then
      return nil, walkErr
    end
    error(walkErr, 0)
  end
  return found
end

-- Pick a usable .nds from a zip: prefer one whose SHA-1 matches a supported
-- version; otherwise fall back to the first .nds so NdsRom.open still reports a
-- precise unknown-ROM error (with the computed hash) for diagnosis.
function RomSource.fromZipData(zipBytes, displayName, versions)
  versions = versions or GameVersion
  local source, err = findNdsCandidate(zipBytes, displayName, versions)
  if not source then
    if err then
      return nil, err
    end
    return nil, Errors.new("ZIP_NO_NDS", "no .nds ROM found in " .. displayName, { name = displayName })
  end
  return source
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
  if isZip(path) then
    return RomSource.fromZipData(data, basename(path))
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
  if not data then
    return nil, Errors.new("ROM_READ_FAILED", "could not read dropped file", { name = droppedFile:getFilename() })
  end
  local name = droppedFile:getFilename()
  if isZip(name) then
    return RomSource.fromZipData(data, basename(name))
  end
  return RomSource.fromString(data, basename(name))
end

local function isNonNegativeInteger(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value) and value < math.huge
end

function RomSource:size()
  return self.data and #self.data or self._size or 0
end

function RomSource:read(offset, length)
  if not self.data then
    return nil, Errors.new("ROM_RELEASED", "ROM source has been released", {})
  end
  if not isNonNegativeInteger(offset) or not isNonNegativeInteger(length) or offset + length > #self.data then
    return nil,
      Errors.new(
        "ROM_READ_OUT_OF_BOUNDS",
        "read outside ROM bounds",
        { offset = offset, length = length, size = #self.data }
      )
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
  if self.data then
    self._size = #self.data
  end
  self.data = nil
end

return RomSource
