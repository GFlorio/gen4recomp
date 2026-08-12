-- Deterministic content fingerprint of the romdump producer source tree:
-- every regular file under romdump/src hashed by relative path and content,
-- aggregated into one SHA-1. Any producer edit (content, add, remove, rename)
-- changes the fingerprint, so the derived cache invalidates without manual
-- compiler-version bookkeeping. mtimes, git state, tests, and docs are
-- deliberately absent. The source tree is injected as a backend so tests use
-- fake trees; appBackend wraps love.filesystem.

local Hashing = require("romdump.src.digest.Hashing")

local ProducerFingerprint = {}

---@class ProducerSourceTree
---@field list fun(): string[]
---@field read fun(path: string): string

-- Aggregate the fingerprint from an injected source-tree backend: list()
-- returns every regular file path relative to romdump/src in any order;
-- read(path) returns that file's contents. Paths are sorted internally, so
-- enumeration order never affects the result.
---@param backend ProducerSourceTree
---@return string
function ProducerFingerprint.compute(backend)
  assert(
    backend and type(backend.list) == "function" and type(backend.read) == "function",
    "ProducerFingerprint.compute requires a source-tree backend"
  )
  local paths = backend.list()
  assert(type(paths) == "table", "source tree listing must be a table")
  table.sort(paths)
  local parts = {}
  for _, path in ipairs(paths) do
    assert(type(path) == "string", "source tree paths must be strings")
    local contents = backend.read(path)
    assert(type(contents) == "string", "source file must read as a string: " .. path)
    parts[#parts + 1] = path .. "\0" .. Hashing.sha1hex(contents)
  end
  return Hashing.sha1hex(table.concat(parts))
end

-- love.filesystem-backed enumeration of this app's own romdump/src tree; the
-- paths it returns are relative to romdump/src.
---@return { list: fun(): string[], read: fun(path: string): string }
function ProducerFingerprint.appBackend()
  assert(love and love.filesystem, "the app backend requires love.filesystem")
  local fs = love.filesystem
  return {
    list = function()
      local files = {}
      local function walk(dir)
        for _, name in ipairs(fs.getDirectoryItems(dir)) do
          local path = dir .. "/" .. name
          local info = fs.getInfo(path)
          if info and info.type == "file" then
            files[#files + 1] = path
          elseif info and info.type == "directory" then
            walk(path)
          end
        end
      end
      walk("src")
      for index, path in ipairs(files) do
        files[index] = path:sub(#"src/" + 1)
      end
      return files
    end,
    read = function(path)
      return fs.read("src/" .. path)
    end,
  }
end

return ProducerFingerprint
