-- Version-scoped persistent user-data owner. Saves live below
-- `saves/<versionId>/`, a sibling namespace to the disposable version cache
-- (`heartgold/`, `soulsilver/`), so no cache-clearing operation -- ROM
-- re-import, derived-cache invalidation, deleting a version root -- is
-- structurally able to reach a save. Path/security rules match CacheFs; the
-- backend is injectable: the default wraps love.filesystem; tests inject an
-- in-memory fake. Love-free under bare LuaJIT.
--
-- Failure convention: every mutating operation reports success only if the
-- backend did; a falsy backend result is translated into a structured SAVE_*
-- error that reaches the caller, and a backend that raises propagates. No
-- mutating method may silently return true after a backend failure.

local Errors = require("libs.rom.src.Errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local GameVersion = require("libs.rom.src.GameVersion")

-- Raise a structured error when a backend mutation reported failure (falsy
-- result, optionally with an error string). The one place the wrapper layer
-- converts backend-reported failures into structured save errors.
local function ensureBackend(ok, err, code, message, context)
  if not ok then
    Errors.raise(code, err or message, context)
  end
  return true
end

---@class SaveFs
---@field versionId string
---@field private _prefix string
---@field private _root string
---@field backend table
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

-- love.filesystem-backed backend, constructed lazily so requiring this module
-- never touches love (keeps the domain testable off-runtime). Mutating backend
-- operations report failure by returning falsy (optionally with an error
-- string); the SaveFs wrappers translate that into structured SAVE_* errors.
local function loveBackend()
  local fs = love.filesystem
  return {
    write = function(_, path, data)
      return fs.write(path, data)
    end,
    read = function(_, path)
      return (fs.read(path))
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
  }
end

function SaveFs.forVersion(versionId, backend)
  local info = GameVersion.info(versionId)
  assert(info, "unknown version id: " .. tostring(versionId))
  local prefix = "saves/" .. versionId .. "/"
  return setmetatable({
    versionId = versionId,
    _prefix = prefix,
    _root = prefix:gsub("/$", ""),
    backend = backend or loveBackend(),
  }, SaveFs)
end

function SaveFs:prefix()
  return self._prefix
end

-- Normalize and confine a relative path, returning the full save-dir path.
-- Raises a structured error on any escape attempt. "" means the save root.
function SaveFs:resolve(relativePath)
  assert(type(relativePath) == "string", "path must be a string")
  local path = relativePath:gsub("\\", "/")
  if path:find("\0", 1, true) then
    Errors.raise("SAVE_PATH_INVALID", "path contains NUL", { path = relativePath })
  end
  if path == "" then
    return self._root
  end
  if path:sub(1, 1) == "/" or path:match("^%a:") then
    Errors.raise("SAVE_PATH_INVALID", "path must be relative", { path = relativePath })
  end
  for component in (path .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." then
      Errors.raise(
        "SAVE_PATH_INVALID",
        "illegal path component: '" .. component .. "'",
        { path = relativePath, component = component }
      )
    end
  end
  return self._root .. "/" .. path
end

function SaveFs:write(relativePath, data)
  local full = self:resolve(relativePath)
  -- Ensure the parent chain exists; the love backend's createDirectory is
  -- mkdir -p, so one call materializes every intermediate directory.
  local parent = full:match("^(.*)/[^/]+$")
  if parent then
    local ok, err = self.backend:createDirectory(parent)
    ensureBackend(ok, err, "SAVE_MKDIR_FAILED", "could not create directory", { path = parent })
  end
  local ok, err = self.backend:write(full, data)
  return ensureBackend(ok, err, "SAVE_WRITE_FAILED", "write failed", { path = full })
end

function SaveFs:read(relativePath)
  return self.backend:read(self:resolve(relativePath))
end

-- Removing an absent path is a no-op (reset runs before the first save
-- exists); removing an existing path that the backend cannot remove raises
-- SAVE_REMOVE_FAILED.
function SaveFs:remove(relativePath)
  local full = self:resolve(relativePath)
  if not self.backend:getInfo(full) then
    return true
  end
  local ok, err = self.backend:remove(full)
  return ensureBackend(ok, err, "SAVE_REMOVE_FAILED", "could not remove", { path = full })
end

-- Atomically replaces destination with an already-written sibling file. The
-- default backend uses the host rename primitive inside LÖVE's save directory.
function SaveFs:replace(sourceRelativePath, destinationRelativePath)
  local source = self:resolve(sourceRelativePath)
  local destination = self:resolve(destinationRelativePath)
  assert(self.backend.replace, "SaveFs backend does not support atomic replacement")
  local ok, err = self.backend:replace(source, destination)
  return ensureBackend(ok, err, "SAVE_REPLACE_FAILED", "replace failed", {
    sourcePath = source,
    destinationPath = destination,
  })
end

function SaveFs:writeLua(relativePath, value)
  return self:write(relativePath, LuaWriter.encode(value))
end

-- Loads a persisted save data file in an empty environment. Must never be
-- pointed at raw ROM file contents.
function SaveFs:loadLua(relativePath)
  local data = self:read(relativePath)
  if data == nil then
    return nil, Errors.new("SAVE_FILE_MISSING", "no such save file", { path = relativePath })
  end
  local chunk, loadErr = loadstring(data, "@" .. relativePath)
  if not chunk then
    return nil, Errors.new("SAVE_LUA_PARSE_FAILED", loadErr, { path = relativePath })
  end
  setfenv(chunk, {})
  local ok, result = pcall(chunk)
  if not ok then
    return nil, Errors.new("SAVE_LUA_EVAL_FAILED", tostring(result), { path = relativePath })
  end
  return result
end

return SaveFs
