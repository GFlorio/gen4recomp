-- Version-scoped private cache. Every path is normalized and confined below the
-- version prefix; absolute paths, drive letters, NUL, and "."/".." components
-- are rejected so no operation can escape its version subtree. The backend is
-- injectable: the default wraps love.filesystem; tests inject an in-memory fake.
-- Path/security logic is love-free and testable under bare LuaJIT.

local Errors = require("libs.rom.src.Errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local GameVersion = require("libs.rom.src.GameVersion")

local CacheFs = {}
CacheFs.__index = CacheFs

-- love.filesystem-backed backend, constructed lazily so requiring this module
-- never touches love (keeps the domain testable off-runtime).
local function loveBackend()
  local fs = love.filesystem
  return {
    write = function(_, path, data)
      local ok, err = fs.write(path, data)
      if not ok then error(Errors.new("CACHE_WRITE_FAILED", err or "write failed", { path = path })) end
      return true
    end,
    read = function(_, path) return (fs.read(path)) end,
    getInfo = function(_, path) return fs.getInfo(path) end,
    createDirectory = function(_, path) return fs.createDirectory(path) end,
    remove = function(_, path) return fs.remove(path) end,
    getDirectoryItems = function(_, path) return fs.getDirectoryItems(path) end,
  }
end

function CacheFs.forVersion(versionId, backend)
  local info = GameVersion.info(versionId)
  assert(info, "unknown version id: " .. tostring(versionId))
  return setmetatable({
    versionId = versionId,
    _prefix = info.cachePrefix,
    _root = info.cachePrefix:gsub("/$", ""),
    backend = backend or loveBackend(),
  }, CacheFs)
end

function CacheFs:prefix()
  return self._prefix
end

-- Normalize and confine a relative path, returning the full save-dir path.
-- Raises a structured error on any escape attempt. "" means the version root.
function CacheFs:resolve(relativePath)
  assert(type(relativePath) == "string", "path must be a string")
  local path = relativePath:gsub("\\", "/")
  if path:find("\0", 1, true) then
    Errors.raise("CACHE_PATH_INVALID", "path contains NUL", { path = relativePath })
  end
  if path == "" then return self._root end
  if path:sub(1, 1) == "/" or path:match("^%a:") then
    Errors.raise("CACHE_PATH_INVALID", "path must be relative", { path = relativePath })
  end
  for component in (path .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." then
      Errors.raise("CACHE_PATH_INVALID", "illegal path component: '" .. component .. "'",
        { path = relativePath, component = component })
    end
  end
  return self._root .. "/" .. path
end

function CacheFs:write(relativePath, data)
  local full = self:resolve(relativePath)
  -- Ensure the parent chain exists; the love backend's createDirectory is
  -- mkdir -p, so one call materializes every intermediate directory.
  local parent = full:match("^(.*)/[^/]+$")
  if parent then self.backend:createDirectory(parent) end
  self.backend:write(full, data)
  return true
end

function CacheFs:read(relativePath)
  return self.backend:read(self:resolve(relativePath))
end

function CacheFs:getInfo(relativePath)
  return self.backend:getInfo(self:resolve(relativePath))
end

function CacheFs:exists(relativePath, expectedType)
  local info = self.backend:getInfo(self:resolve(relativePath))
  if not info then return false end
  if expectedType then return info.type == expectedType end
  return true
end

function CacheFs:createDirectory(relativePath)
  self.backend:createDirectory(self:resolve(relativePath))
  return true
end

function CacheFs:remove(relativePath)
  self.backend:remove(self:resolve(relativePath))
  return true
end

function CacheFs:removeTree(relativePath)
  local root = self:resolve(relativePath)
  local function rec(fullPath)
    local info = self.backend:getInfo(fullPath)
    if not info then return end
    if info.type == "directory" then
      for _, name in ipairs(self.backend:getDirectoryItems(fullPath)) do
        rec(fullPath .. "/" .. name)
      end
    end
    self.backend:remove(fullPath)
  end
  rec(root)
  return true
end

function CacheFs:writeLua(relativePath, value)
  return self:write(relativePath, LuaWriter.encode(value))
end

-- Loads a generated/checked-in Lua data file in an empty environment. Must
-- never be pointed at raw ROM file contents.
function CacheFs:loadLua(relativePath)
  local data = self:read(relativePath)
  if data == nil then
    return nil, Errors.new("CACHE_FILE_MISSING", "no such cache file", { path = relativePath })
  end
  local chunk, loadErr = loadstring(data, "@" .. relativePath)
  if not chunk then
    return nil, Errors.new("CACHE_LUA_PARSE_FAILED", loadErr, { path = relativePath })
  end
  setfenv(chunk, {})
  local ok, result = pcall(chunk)
  if not ok then
    return nil, Errors.new("CACHE_LUA_EVAL_FAILED", tostring(result), { path = relativePath })
  end
  return result
end

return CacheFs
