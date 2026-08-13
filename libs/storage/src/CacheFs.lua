-- Version-scoped private cache. Every path is normalized and confined below the
-- version prefix; absolute paths, drive letters, NUL, and "."/".." components
-- are rejected so no operation can escape its version subtree. Roots are
-- structural (`<versionId>/`, `staging/<versionId>/`): a version id is any safe
-- path component, and which ids exist is the ROM catalog's business, not this
-- package's. The backend is injectable: the default wraps love.filesystem;
-- tests inject an in-memory fake. Path/security logic is love-free and testable
-- under bare LuaJIT.
--
-- Failure convention: every mutating operation reports success only if the
-- backend did; a falsy backend result is translated into a structured CACHE_*
-- error that reaches the caller, and a backend that raises propagates. No
-- mutating method may silently return true after a backend failure, so
-- publication logic can rely on a raise meaning "nothing happened" (or, for
-- cleanup, "the failure surfaced").

local Errors = require("libs.errors.src.Errors")
local StorageErrors = require("libs.storage.src.errors")
local LuaWriter = require("libs.codec.src.LuaWriter")

-- A version id is a structural path component: it must be able to name exactly
-- one namespace below the cache root. Catalog membership (which ids exist) is
-- validated by the ROM catalog, not here.
local function validateVersionId(versionId)
  assert(type(versionId) == "string", "version id must be a string")
  assert(
    versionId:match("^[%w%-_]+$") ~= nil,
    "version id must be a single safe path component: " .. tostring(versionId)
  )
end

-- Raise a structured error when a backend mutation reported failure (falsy
-- result, optionally with an error string). The one place the wrapper layer
-- converts backend-reported failures into structured cache errors.
local function ensureBackend(ok, err, code, message, context)
  if not ok then
    Errors.raise(code, err or message, context)
  end
  return true
end

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
---@field replaceAt fun(self: CacheFs, sourcePath: string, destinationPath: string): boolean
---@field removeTree fun(self: CacheFs, relativePath: string): boolean
---@field removeStagedTree fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field publishFromStage fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field writeLua fun(self: CacheFs, relativePath: string, value: table): boolean
---@field loadLua fun(self: CacheFs, relativePath: string): table?, Errors.Error?
local CacheFs = {}
CacheFs.__index = CacheFs

-- The sibling path a completed live root is moved to before a staged tree is
-- renamed into place; a crash between the two renames leaves the previous dump
-- here for removeStagedTree to discard at the next import. ArtifactPublisher
-- uses the same suffix for per-root asides inside an artifact stage.
CacheFs.STAGING_OLD_SUFFIX = ".old"

-- love.filesystem-backed backend, constructed lazily so requiring this module
-- never touches love (keeps the domain testable off-runtime). Mutating backend
-- operations report failure by returning falsy (optionally with an error
-- string); the CacheFs wrappers translate that into structured CACHE_* errors.
local function loveBackend()
  local fs = love.filesystem
  return {
    write = function(_, path, data)
      return fs.write(path, data)
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
      return os.rename(root .. "/" .. sourcePath, root .. "/" .. destinationPath)
    end,
    getDirectoryItems = function(_, path)
      return fs.getDirectoryItems(path)
    end,
  }
end

function CacheFs.forVersion(versionId, backend)
  validateVersionId(versionId)
  return setmetatable({
    versionId = versionId,
    _prefix = versionId .. "/",
    _root = versionId,
    backend = backend or loveBackend(),
  }, CacheFs)
end

-- A CacheFs rooted at the disposable `staging/<versionId>/` namespace, a
-- sibling of the live version root. A completed staging tree is published over
-- the live root with publishFromStage; stale staging is discarded at the next
-- import.
function CacheFs.forStaging(versionId, backend)
  validateVersionId(versionId)
  local prefix = "staging/" .. versionId .. "/"
  return setmetatable({
    versionId = versionId,
    _prefix = prefix,
    _root = prefix:gsub("/$", ""),
    backend = backend or loveBackend(),
  }, CacheFs)
end

-- A CacheFs rooted at the disposable `staging/<versionId>/<name>/` namespace,
-- mirroring the live cache-relative layout for one generated artifact. Used by
-- ArtifactPublisher for the staged publication of derived caches; like the ROM
-- staging root it is swept with the rest of `staging/<versionId>/` at the next
-- import. `name` must be a single safe path component.
function CacheFs.forArtifactStage(versionId, name, backend)
  validateVersionId(versionId)
  assert(name:match("^[%w%-_]+$"), "artifact name must be a single safe path component")
  local prefix = "staging/" .. versionId .. "/" .. name .. "/"
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
    Errors.raise(StorageErrors.CACHE_PATH_INVALID, "path contains NUL", { path = relativePath })
  end
  if path == "" then
    return self._root
  end
  if path:sub(1, 1) == "/" or path:match("^%a:") then
    Errors.raise(StorageErrors.CACHE_PATH_INVALID, "path must be relative", { path = relativePath })
  end
  for component in (path .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." then
      Errors.raise(
        StorageErrors.CACHE_PATH_INVALID,
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
    local ok, err = self.backend:createDirectory(parent)
    ensureBackend(ok, err, StorageErrors.CACHE_MKDIR_FAILED, "could not create directory", { path = parent })
  end
  local ok, err = self.backend:write(full, data)
  return ensureBackend(ok, err, StorageErrors.CACHE_WRITE_FAILED, "write failed", { path = full })
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
  local full = self:resolve(relativePath)
  local ok, err = self.backend:createDirectory(full)
  return ensureBackend(ok, err, StorageErrors.CACHE_MKDIR_FAILED, "could not create directory", { path = full })
end

-- Removing an absent path is a no-op; removing an existing path that the
-- backend cannot remove raises CACHE_REMOVE_FAILED.
function CacheFs:remove(relativePath)
  local full = self:resolve(relativePath)
  if not self.backend:getInfo(full) then
    return true
  end
  local ok, err = self.backend:remove(full)
  return ensureBackend(ok, err, StorageErrors.CACHE_REMOVE_FAILED, "could not remove", { path = full })
end

-- Atomically replaces destination with an already-written sibling file. The
-- default backend uses the host rename primitive inside LÖVE's save directory.
function CacheFs:replace(sourceRelativePath, destinationRelativePath)
  local source = self:resolve(sourceRelativePath)
  local destination = self:resolve(destinationRelativePath)
  assert(self.backend.replace, "CacheFs backend does not support atomic replacement")
  return self:replaceAt(source, destination)
end

-- Backend rename at save-directory-absolute paths with the standard failure
-- convention (CACHE_REPLACE_FAILED on a falsy backend result). Used by
-- replace() and by the publish/rollback logic in this module and
-- ArtifactPublisher, so a backend that reports failure can never make
-- publication report success.
function CacheFs:replaceAt(sourcePath, destinationPath)
  local ok, err = self.backend:replace(sourcePath, destinationPath)
  return ensureBackend(ok, err, StorageErrors.CACHE_REPLACE_FAILED, "replace failed", {
    sourcePath = sourcePath,
    destinationPath = destinationPath,
  })
end

function CacheFs:removeTree(relativePath)
  self:_removeTreeAt(self:resolve(relativePath))
  return true
end

-- Recursively remove a save-directory-absolute path; a no-op when absent.
-- Any backend-reported removal or enumeration failure raises
-- CACHE_REMOVE_FAILED instead of silently reporting success.
function CacheFs:_removeTreeAt(fullPath)
  local function rec(path)
    local info = self.backend:getInfo(path)
    if not info then
      return
    end
    if info.type == "directory" then
      local items = self.backend:getDirectoryItems(path)
      ensureBackend(items, nil, StorageErrors.CACHE_REMOVE_FAILED, "could not list directory", { path = path })
      for _, name in ipairs(items) do
        rec(path .. "/" .. name)
      end
    end
    local ok, err = self.backend:remove(path)
    ensureBackend(ok, err, StorageErrors.CACHE_REMOVE_FAILED, "could not remove", { path = path })
  end
  rec(fullPath)
end

-- Discard every staged output for this version: the staging root and any
-- orphaned previous root (`staging/<versionId>.old`) a crash mid-publish left
-- behind. Staging is disposable generated data; a fresh extraction rebuilds it
-- from the validated ROM. The live root is never touched.
function CacheFs:removeStagedTree(stagingCache)
  self:_removeTreeAt(stagingCache:resolve(""))
  self:_removeTreeAt(stagingCache:resolve("") .. CacheFs.STAGING_OLD_SUFFIX)
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
  local oldRoot = stageRoot .. CacheFs.STAGING_OLD_SUFFIX
  self:_removeTreeAt(oldRoot)
  local movedLiveAside = false
  if self:exists("", "directory") then
    self:replaceAt(liveRoot, oldRoot)
    movedLiveAside = true
  end
  local ok, err = pcall(self.replaceAt, self, stageRoot, liveRoot)
  if not ok then
    if movedLiveAside then
      self:replaceAt(oldRoot, liveRoot)
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
    return nil, Errors.new(StorageErrors.CACHE_FILE_MISSING, "no such cache file", { path = relativePath })
  end
  local chunk, loadErr = loadstring(data, "@" .. relativePath)
  if not chunk then
    return nil, Errors.new(StorageErrors.CACHE_LUA_PARSE_FAILED, loadErr, { path = relativePath })
  end
  setfenv(chunk, {})
  local ok, result = pcall(chunk)
  if not ok then
    return nil, Errors.new(StorageErrors.CACHE_LUA_EVAL_FAILED, tostring(result), { path = relativePath })
  end
  return result
end

-- The one module a generated chunk may require: the gen4 script DSL emitted
-- by the script cache generator. Mirrors ScriptLoader's resource-loader
-- allowlist; anything wider would let generated cache content reach (and
-- corrupt) process-wide package state.
local ALLOWED_MODULES = { ["gen4.script"] = true }

local function moduleRequire(name)
  assert(ALLOWED_MODULES[name], "generated modules may only require gen4.script")
  return require(name)
end

-- Loads a generated Lua module (a file that `require`s other modules) in an
-- environment whose only entry is a require restricted to the gen4.script
-- allowlist. Used by the script-cache readback and by runtime loaders that
-- consume generated DSL modules. Must never be pointed at raw ROM file
-- contents. A module requiring outside the allowlist fails to load.
function CacheFs:loadModule(relativePath)
  local data = self:read(relativePath)
  if data == nil then
    return nil, Errors.new(StorageErrors.CACHE_FILE_MISSING, "no such cache file", { path = relativePath })
  end
  local chunk, loadErr = loadstring(data, "@" .. relativePath)
  if not chunk then
    return nil, Errors.new(StorageErrors.CACHE_LUA_PARSE_FAILED, loadErr, { path = relativePath })
  end
  setfenv(chunk, { require = moduleRequire })
  local ok, result = pcall(chunk)
  if not ok then
    return nil, Errors.new(StorageErrors.CACHE_LUA_EVAL_FAILED, tostring(result), { path = relativePath })
  end
  return result
end

return CacheFs
