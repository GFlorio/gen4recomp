-- Version-scoped persistent user-data owner. Saves live below
-- `saves/<versionId>/`, a sibling namespace to the disposable version cache
-- (`heartgold/`, `soulsilver/`), so no cache-clearing operation -- ROM
-- re-import, derived-cache invalidation, deleting a version root -- is
-- structurally able to reach a save. The version id is any safe path component;
-- which ids exist is the ROM catalog's business, not this package's.
-- Confinement, backend handling, parent creation, and Lua loading share the
-- internal ScopedFs mechanics with CacheFs; the save root, allowed
-- mutations, and SAVE_* error namespace stay its own, and it never gains
-- cache tree-deletion or publication operations. The backend is injectable:
-- the default wraps love.filesystem; tests inject an in-memory fake.
-- Love-free under bare LuaJIT.
--
-- Failure convention: every mutating operation reports success only if the
-- backend did; a falsy backend result is translated into a structured SAVE_*
-- error that reaches the caller, and a backend that raises propagates. No
-- mutating method may silently return true after a backend failure.

local LuaWriter = require("libs.codec.src.LuaWriter")
local ScopedFs = require("libs.storage.src.ScopedFs")
local StorageErrors = require("libs.storage.src.errors")

-- The SAVE_* codes this type raises through the shared mechanics.
local SAVE_ERRORS = {
  PATH_INVALID = StorageErrors.SAVE_PATH_INVALID,
  FILE_MISSING = StorageErrors.SAVE_FILE_MISSING,
  READ_FAILED = StorageErrors.SAVE_READ_FAILED,
  LUA_PARSE_FAILED = StorageErrors.SAVE_LUA_PARSE_FAILED,
  LUA_EVAL_FAILED = StorageErrors.SAVE_LUA_EVAL_FAILED,
  MKDIR_FAILED = StorageErrors.SAVE_MKDIR_FAILED,
  WRITE_FAILED = StorageErrors.SAVE_WRITE_FAILED,
  REMOVE_FAILED = StorageErrors.SAVE_REMOVE_FAILED,
  REPLACE_FAILED = StorageErrors.SAVE_REPLACE_FAILED,
}

---@class SaveFs
---@field versionId string
---@field private _prefix string
---@field private _root string
---@field backend ScopedFs.Backend
---@field prefix fun(self: SaveFs): string
---@field resolve fun(self: SaveFs, relativePath: string): string
---@field write fun(self: SaveFs, relativePath: string, data: string): boolean
---@field read fun(self: SaveFs, relativePath: string): string?
---@field remove fun(self: SaveFs, relativePath: string): boolean
---@field replace fun(self: SaveFs, sourceRelativePath: string, destinationRelativePath: string): boolean
---@field writeLua fun(self: SaveFs, relativePath: string, value: table): boolean
---@field loadLua fun(self: SaveFs, relativePath: string): table?, Errors.Error?
local SaveFs = {}
SaveFs.__index = SaveFs

---@param versionId string
---@param backend table|nil
---@return SaveFs
function SaveFs.forVersion(versionId, backend)
  ScopedFs.validateVersionId(versionId)
  return setmetatable({
    versionId = versionId,
    _prefix = "saves/" .. versionId .. "/",
    _root = "saves/" .. versionId,
    backend = backend or ScopedFs.loveBackend(),
  }, SaveFs)
end

function SaveFs:prefix()
  return self._prefix
end

-- Normalize and confine a relative path, returning the full save-dir path.
-- Raises a structured error on any escape attempt. "" means the save root.
function SaveFs:resolve(relativePath)
  return ScopedFs.resolve(self._root, relativePath, SAVE_ERRORS)
end

function SaveFs:write(relativePath, data)
  return ScopedFs.write(self.backend, self:resolve(relativePath), data, SAVE_ERRORS)
end

function SaveFs:read(relativePath)
  return self.backend:read(self:resolve(relativePath))
end

-- Removing an absent path is a no-op (reset runs before the first save
-- exists); removing an existing path that the backend cannot remove raises
-- SAVE_REMOVE_FAILED.
function SaveFs:remove(relativePath)
  return ScopedFs.remove(self.backend, self:resolve(relativePath), SAVE_ERRORS)
end

-- Atomically replaces destination with an already-written sibling file. The
-- default backend uses the host rename primitive inside LÖVE's save directory.
function SaveFs:replace(sourceRelativePath, destinationRelativePath)
  local source = self:resolve(sourceRelativePath)
  local destination = self:resolve(destinationRelativePath)
  return ScopedFs.replace(self.backend, source, destination, SAVE_ERRORS)
end

function SaveFs:writeLua(relativePath, value)
  return self:write(relativePath, LuaWriter.encode(value))
end

-- Loads a persisted save data file in an empty environment. Must never be
-- pointed at raw ROM file contents.
function SaveFs:loadLua(relativePath)
  return ScopedFs.loadChunk(self.backend, self:resolve(relativePath), relativePath, SAVE_ERRORS)
end

return SaveFs
