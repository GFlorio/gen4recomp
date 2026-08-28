-- Low-level mechanics shared by the two version-scoped filesystem types
-- (SaveFs, CacheFs): version-root validation, path confinement, the love
-- backend wrapper, parent-directory creation, backend failure translation,
-- and the Lua load plumbing. Not a capability surface: each scoped type
-- keeps its own root, mutation set, and error namespace, and only the truly
-- identical parts live here. Pure domain module: no love dependency (love
-- is captured lazily by loveBackend, so requiring this module is safe under
-- bare LuaJIT).

local Errors = require("libs.errors.src.Errors")

---@class ScopedFs.Info
---@field type string

---@class ScopedFs.Backend
---@field write fun(self: ScopedFs.Backend, path: string, data: string): boolean, string?
---@field read fun(self: ScopedFs.Backend, path: string): string?, string?
---@field getInfo fun(self: ScopedFs.Backend, path: string): ScopedFs.Info?
---@field createDirectory fun(self: ScopedFs.Backend, path: string): boolean, string?
---@field remove fun(self: ScopedFs.Backend, path: string): boolean, string?
---@field replace fun(self: ScopedFs.Backend, sourcePath: string, destinationPath: string): boolean, string?
---@field getDirectoryItems fun(self: ScopedFs.Backend, path: string): string[], string?

---@alias ScopedFs.ErrorCodes table<string, string>

local ScopedFs = {}

-- A version id is a structural path component: it must be able to name
-- exactly one namespace below a scoped root. Catalog membership (which ids
-- exist) is validated by the ROM catalog, not here.
function ScopedFs.validateVersionId(versionId)
  assert(type(versionId) == "string", "version id must be a string")
  assert(
    versionId:match("^[%w%-_]+$") ~= nil,
    "version id must be a single safe path component: " .. tostring(versionId)
  )
end

-- love.filesystem-backed backend, constructed lazily so requiring this
-- module never touches love. Mutating backend operations report failure by
-- returning falsy (optionally with an error string); the scoped wrappers
-- translate that into structured errors. read preserves the backend's
-- (data, size) / (nil, errorMessage) two-value shape so a read failure
-- stays distinguishable from a missing file at the load boundary.
---@return ScopedFs.Backend
function ScopedFs.loveBackend()
  local fs = love.filesystem
  return {
    write = function(_, path, data)
      return fs.write(path, data)
    end,
    read = function(_, path)
      return fs.read(path)
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

-- Raise a structured error when a backend mutation reported failure (falsy
-- result, optionally with an error string). The one place the wrapper layer
-- converts backend-reported failures into structured scoped-filesystem
-- errors.
---@param ok boolean
---@param err string?
---@param code string
---@param message string
---@param context Errors.Context
---@return true
function ScopedFs.ensureBackend(ok, err, code, message, context)
  if not ok then
    Errors.raise(code, err or message, context)
  end
  return true
end

-- Normalize and confine a relative path, returning the full scoped path.
-- Raises a structured error on any escape attempt. "" means the scoped
-- root. `codes` is the caller's per-type error-code table.
---@param root string
---@param relativePath string
---@param codes ScopedFs.ErrorCodes
---@return string
function ScopedFs.resolve(root, relativePath, codes)
  assert(type(relativePath) == "string", "path must be a string")
  local path = relativePath:gsub("\\", "/")
  if path:find("\0", 1, true) then
    Errors.raise(codes.PATH_INVALID, "path contains NUL", { path = relativePath })
  end
  if path == "" then
    return root
  end
  if path:sub(1, 1) == "/" or path:match("^%a:") then
    Errors.raise(codes.PATH_INVALID, "path must be relative", { path = relativePath })
  end
  for component in (path .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." then
      Errors.raise(
        codes.PATH_INVALID,
        "illegal path component: '" .. component .. "'",
        { path = relativePath, component = component }
      )
    end
  end
  return root .. "/" .. path
end

-- Write a file below the scoped root, materializing the parent chain first
-- (the love backend's createDirectory is mkdir -p, so one call creates every
-- intermediate directory). A backend-reported failure raises MKDIR_FAILED or
-- WRITE_FAILED.
---@param backend ScopedFs.Backend
---@param fullPath string
---@param data string
---@param codes ScopedFs.ErrorCodes
---@return true
function ScopedFs.write(backend, fullPath, data, codes)
  local parent = fullPath:match("^(.*)/[^/]+$")
  if parent then
    local ok, err = backend:createDirectory(parent)
    ScopedFs.ensureBackend(ok, err, codes.MKDIR_FAILED, "could not create directory", { path = parent })
  end
  local ok, err = backend:write(fullPath, data)
  return ScopedFs.ensureBackend(ok, err, codes.WRITE_FAILED, "write failed", { path = fullPath })
end

-- Removing an absent path is a no-op; removing an existing path that the
-- backend cannot remove raises REMOVE_FAILED.
---@param backend ScopedFs.Backend
---@param fullPath string
---@param codes ScopedFs.ErrorCodes
---@return true
function ScopedFs.remove(backend, fullPath, codes)
  if not backend:getInfo(fullPath) then
    return true
  end
  local ok, err = backend:remove(fullPath)
  return ScopedFs.ensureBackend(ok, err, codes.REMOVE_FAILED, "could not remove", { path = fullPath })
end

-- Atomically replaces destination with an already-written sibling file. The
-- default backend uses the host rename primitive inside LÖVE's save
-- directory.
---@param backend ScopedFs.Backend
---@param sourcePath string
---@param destinationPath string
---@param codes ScopedFs.ErrorCodes
---@return true
function ScopedFs.replace(backend, sourcePath, destinationPath, codes)
  assert(backend.replace, "backend does not support atomic replacement")
  local ok, err = backend:replace(sourcePath, destinationPath)
  return ScopedFs.ensureBackend(ok, err, codes.REPLACE_FAILED, "replace failed", {
    sourcePath = sourcePath,
    destinationPath = destinationPath,
  })
end

-- Read and evaluate a persisted Lua data file in the given environment.
-- Returns (result, nil) or (nil, structured error). A file the backend
-- reports absent is FILE_MISSING; a file that exists but cannot be read is
-- READ_FAILED with the backend's error message preserved -- the two must
-- stay distinguishable at the load boundary. Chunk failures raise
-- LUA_PARSE_FAILED / LUA_EVAL_FAILED. Must never be pointed at raw ROM file
-- contents.
---@param backend ScopedFs.Backend
---@param fullPath string
---@param relativePath string
---@param codes ScopedFs.ErrorCodes
---@param env table<string, function>?
---@return table?, Errors.Error?
function ScopedFs.loadChunk(backend, fullPath, relativePath, codes, env)
  if not backend:getInfo(fullPath) then
    return nil, Errors.new(codes.FILE_MISSING, "no such file", { path = relativePath })
  end
  local data, readErr = backend:read(fullPath)
  if data == nil then
    return nil, Errors.new(codes.READ_FAILED, readErr or "read failed", { path = relativePath })
  end
  local chunk, loadErr = loadstring(data, "@" .. relativePath)
  if not chunk then
    return nil, Errors.new(codes.LUA_PARSE_FAILED, assert(loadErr), { path = relativePath })
  end
  setfenv(chunk, env or {})
  local ok, result = pcall(chunk)
  if not ok then
    return nil, Errors.new(codes.LUA_EVAL_FAILED, tostring(result), { path = relativePath })
  end
  return result
end

return ScopedFs
