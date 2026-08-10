-- Version-scoped private cache. Every path is normalized and confined below the
-- version prefix; absolute paths, drive letters, NUL, and "."/".." components
-- are rejected so no operation can escape its version subtree. The backend is
-- injectable: the default wraps love.filesystem; tests inject an in-memory fake.
-- Path/security logic is love-free and testable under bare LuaJIT.

local Errors = require("libs.rom.src.Errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local GameVersion = require("libs.rom.src.GameVersion")

---@class CacheFs
---@field versionId string
---@field private _prefix string
---@field private _root string
---@field backend table
---@field prefix fun(self: CacheFs): string
---@field resolve fun(self: CacheFs, relativePath: string): string
---@field write fun(self: CacheFs, relativePath: string, data: string): boolean
---@field read fun(self: CacheFs, relativePath: string): string?
---@field getInfo fun(self: CacheFs, relativePath: string): table?
---@field exists fun(self: CacheFs, relativePath: string, expectedType?: string): boolean
---@field createDirectory fun(self: CacheFs, relativePath: string): boolean
---@field remove fun(self: CacheFs, relativePath: string): boolean
---@field replace fun(self: CacheFs, sourceRelativePath: string, destinationRelativePath: string): boolean
---@field removeTree fun(self: CacheFs, relativePath: string): boolean
---@field removeStagedTree fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field publishFromStage fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field writeLua fun(self: CacheFs, relativePath: string, value: table): boolean
---@field loadLua fun(self: CacheFs, relativePath: string): table?, Errors.Error?
local CacheFs = {}
CacheFs.__index = CacheFs

-- The sibling path a completed live root is moved to before a staged tree is
-- renamed into place; a crash between the two renames leaves the previous dump
-- here for removeStagedTree to discard at the next import.
local STAGING_OLD_SUFFIX = ".old"

-- love.filesystem-backed backend, constructed lazily so requiring this module
-- never touches love (keeps the domain testable off-runtime).
local function loveBackend()
  local fs = love.filesystem
  return {
    write = function(_, path, data)
      local ok, err = fs.write(path, data)
      if not ok then
        error(Errors.new("CACHE_WRITE_FAILED", err or "write failed", { path = path }))
      end
      return true
    end,
    read = function(_, path)
      return (fs.read(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(path)
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(path)
    end,
    remove = function(_, path)
      return fs.remove(path)
    end,
    replace = function(_, sourcePath, destinationPath)
      local root = fs.getSaveDirectory()
      local ok, err = os.rename(root .. "/" .. sourcePath, root .. "/" .. destinationPath)
      if not ok then
        error(Errors.new("CACHE_REPLACE_FAILED", err or "replace failed", {
          sourcePath = sourcePath,
          destinationPath = destinationPath,
        }))
      end
      return true
    end,
    getDirectoryItems = function(_, path)
      return fs.getDirectoryItems(path)
    end,
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

-- A CacheFs rooted at the disposable `staging/<versionId>/` namespace, a
-- sibling of the live version root. A completed staging tree is published over
-- the live root with publishFromStage; stale staging is discarded at the next
-- import. Derives its prefix like SaveFs rather than owning one in GameVersion.
function CacheFs.forStaging(versionId, backend)
  local info = GameVersion.info(versionId)
  assert(info, "unknown version id: " .. tostring(versionId))
  local prefix = "staging/" .. versionId .. "/"
  return setmetatable({
    versionId = versionId,
    _prefix = prefix,
    _root = prefix:gsub("/$", ""),
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
  if path == "" then
    return self._root
  end
  if path:sub(1, 1) == "/" or path:match("^%a:") then
    Errors.raise("CACHE_PATH_INVALID", "path must be relative", { path = relativePath })
  end
  for component in (path .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." then
      Errors.raise(
        "CACHE_PATH_INVALID",
        "illegal path component: '" .. component .. "'",
        { path = relativePath, component = component }
      )
    end
  end
  return self._root .. "/" .. path
end

function CacheFs:write(relativePath, data)
  local full = self:resolve(relativePath)
  -- Ensure the parent chain exists; the love backend's createDirectory is
  -- mkdir -p, so one call materializes every intermediate directory.
  local parent = full:match("^(.*)/[^/]+$")
  if parent then
    self.backend:createDirectory(parent)
  end
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
  if not info then
    return false
  end
  if expectedType then
    return info.type == expectedType
  end
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

-- Atomically replaces destination with an already-written sibling file. The
-- default backend uses the host rename primitive inside LÖVE's save directory.
function CacheFs:replace(sourceRelativePath, destinationRelativePath)
  local source = self:resolve(sourceRelativePath)
  local destination = self:resolve(destinationRelativePath)
  assert(self.backend.replace, "CacheFs backend does not support atomic replacement")
  self.backend:replace(source, destination)
  return true
end

function CacheFs:removeTree(relativePath)
  self:_removeTreeAt(self:resolve(relativePath))
  return true
end

-- Recursively remove a save-directory-absolute path; a no-op when absent.
function CacheFs:_removeTreeAt(fullPath)
  local function rec(path)
    local info = self.backend:getInfo(path)
    if not info then
      return
    end
    if info.type == "directory" then
      for _, name in ipairs(self.backend:getDirectoryItems(path)) do
        rec(path .. "/" .. name)
      end
    end
    self.backend:remove(path)
  end
  rec(fullPath)
end

-- Discard every staged output for this version: the staging root and any
-- orphaned previous root (`staging/<versionId>.old`) a crash mid-publish left
-- behind. Staging is disposable generated data; a fresh extraction rebuilds it
-- from the validated ROM. The live root is never touched.
function CacheFs:removeStagedTree(stagingCache)
  self:_removeTreeAt(stagingCache:resolve(""))
  self:_removeTreeAt(stagingCache:resolve("") .. STAGING_OLD_SUFFIX)
  return true
end

-- Publish a completed staging tree as the new live version root. The live root
-- is first moved aside to the staging sibling `<stagingRoot>.old`, the staging
-- root is then renamed into place, and only after it lands is the previous root
-- removed. If the staging root cannot land, the previous root is renamed back
-- and the failure re-raised, so a failed publish leaves the prior dump intact.
-- Both moves are single backend renames; a process crash between them leaves
-- the previous dump at `<stagingRoot>.old`, which removeStagedTree discards at
-- the next import.
function CacheFs:publishFromStage(stagingCache)
  local liveRoot = self:resolve("")
  local stageRoot = stagingCache:resolve("")
  local oldRoot = stageRoot .. STAGING_OLD_SUFFIX
  self:_removeTreeAt(oldRoot)
  local movedLiveAside = false
  if self:exists("", "directory") then
    self.backend:replace(liveRoot, oldRoot)
    movedLiveAside = true
  end
  local ok, err = pcall(self.backend.replace, self.backend, stageRoot, liveRoot)
  if not ok then
    if movedLiveAside then
      self.backend:replace(oldRoot, liveRoot)
    end
    error(err, 0)
  end
  self:_removeTreeAt(oldRoot)
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

-- Loads a generated Lua module (a file that `require`s other modules) with
-- the standard library and require access. Used by the script-cache readback
-- and by runtime loaders that consume generated DSL modules. Must never be
-- pointed at raw ROM file contents.
function CacheFs:loadModule(relativePath)
  local data = self:read(relativePath)
  if data == nil then
    return nil, Errors.new("CACHE_FILE_MISSING", "no such cache file", { path = relativePath })
  end
  local chunk, loadErr = loadstring(data, "@" .. relativePath)
  if not chunk then
    return nil, Errors.new("CACHE_LUA_PARSE_FAILED", loadErr, { path = relativePath })
  end
  setfenv(chunk, { require = require, package = package })
  local ok, result = pcall(chunk)
  if not ok then
    return nil, Errors.new("CACHE_LUA_EVAL_FAILED", tostring(result), { path = relativePath })
  end
  return result
end

return CacheFs
