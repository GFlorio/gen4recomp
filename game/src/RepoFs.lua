-- Repo-filesystem adapter for the script override system: reads checked-in
-- content under the repository root (e.g. `data/scripts/overrides`) that
-- lives outside the LÖVE source and save directories. The LÖVE build's
-- love.filesystem.mount cannot attach host directories, so this adapter uses
-- plain io (the repo root comes from love.filesystem.getSourceBaseDirectory
-- at construction). It implements the read-shaped contract the script loader
-- consumes; the loader enumerates overrides through the checked-in manifest,
-- never through directory listing. Interface layer: never imported by domain
-- modules.

---@class RepoFs
---@field private _root string
local RepoFs = {}
RepoFs.__index = RepoFs

---@param root string repo root (source base directory)
---@return RepoFs
function RepoFs.new(root)
  assert(type(root) == "string" and root ~= "", "repo fs requires the repo root")
  return setmetatable({ _root = root }, RepoFs)
end

-- Confines a repo-relative path below the root: normalize separators, reject
-- absolute paths and `.`/`..` components, then verify the joined canonical
-- path still sits inside the root. Rejection raises; a missing normal file
-- stays nil (read's io.open failure).
function RepoFs:_full(relativePath)
  assert(type(relativePath) == "string", "repo fs paths are repo-relative")
  local canonical = relativePath:gsub("\\", "/")
  assert(canonical:sub(1, 1) ~= "/", "repo fs paths are repo-relative")
  local components = {}
  for component in canonical:gmatch("[^/]+") do
    assert(component ~= "." and component ~= "..", "repo fs paths may not contain traversal components")
    components[#components + 1] = component
  end
  assert(#components > 0, "repo fs paths are repo-relative")
  local full = self._root .. "/" .. table.concat(components, "/")
  assert(full:sub(1, #self._root) == self._root, "repo fs path escapes the repo root")
  return full
end

---@param path string
---@return string|nil
function RepoFs:read(path)
  local handle = io.open(self:_full(path), "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a")
  handle:close()
  return data
end

return RepoFs
