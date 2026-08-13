-- Real-filesystem adapter for discovery. `love.filesystem` is rooted at the
-- game app directory (`love game/`), so repo-relative paths such as
-- `libs/codec/tests` are invisible to it — a directory listing through LÖVE
-- silently returns nothing, which would silently discover zero suites. This
-- adapter indexes the approved roots once through `find` against the real
-- source base directory and answers the `getDirectoryItems`/`getInfo` subset of
-- `love.filesystem` that discovery consumes. The lookup half is shared with the
-- runner's fake corpus through `fromFileSet`.
--
-- UNIX-only by intent: the repository's scripts and dev container already
-- assume a UNIX-like environment.

local RepoFiles = {}

-- Single-quote a path for the shell: an apostrophe inside the path is escaped
-- with the standard `'\''` sequence, so a root whose name contains one is
-- indexed instead of turning the `find` command into a syntax error.
local function shellQuote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function indexRoot(files, baseDirectory, path)
  -- stderr is discarded: a missing or unreadable root surfaces as the empty
  -- index assertion below rather than as noise in the test output.
  local command = "find " .. shellQuote(baseDirectory .. "/" .. path) .. " -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. path .. ": io.popen unavailable")
  local prefix = baseDirectory .. "/"
  local count = 0
  for line in pipe:lines() do
    assert(line:sub(1, #prefix) == prefix, "unexpected path outside the repository: " .. line)
    files[line:sub(#prefix + 1)] = true
    count = count + 1
  end
  pipe:close()
  assert(count > 0, "test root indexed no Lua files: " .. path)
end

-- The reader contract discovery consumes, matching the subset of
-- `love.filesystem` the runner uses.
---@class RunnerFileSystem
---@field getDirectoryItems fun(path: string): string[]
---@field getInfo fun(path: string): { type: string }|nil

-- The reader contract over an in-memory set of repo-relative file paths. Also
-- used by the runner's fake corpus, so the fake and the real adapter answer
-- discovery identically by construction.
---@param files table<string, true> repo-relative file path -> true
---@return RunnerFileSystem
function RepoFiles.fromFileSet(files)
  local function getDirectoryItems(path)
    local prefix = path .. "/"
    local seen, out = {}, {}
    for file in pairs(files) do
      if file:sub(1, #prefix) == prefix then
        local entry = file:sub(#prefix + 1):match("^([^/]+)")
        if entry ~= nil and not seen[entry] then
          seen[entry] = true
          out[#out + 1] = entry
        end
      end
    end
    return out
  end

  local function getInfo(path)
    if files[path] then
      return { type = "file" }
    end
    local prefix = path .. "/"
    for file in pairs(files) do
      if file:sub(1, #prefix) == prefix then
        return { type = "directory" }
      end
    end
    return nil
  end

  return { getDirectoryItems = getDirectoryItems, getInfo = getInfo }
end

-- Indexes `paths` (repo-relative directories) below `baseDirectory`.
---@param baseDirectory string absolute path of the repository root
---@param paths string[] repo-relative directories to index
---@return RunnerFileSystem
function RepoFiles.new(baseDirectory, paths)
  assert(type(baseDirectory) == "string" and baseDirectory ~= "", "RepoFiles needs a base directory")
  local files = {}
  for _, path in ipairs(paths) do
    indexRoot(files, baseDirectory, path)
  end
  return RepoFiles.fromFileSet(files)
end

return RepoFiles
