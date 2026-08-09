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

function RepoFs:_full(relativePath)
  assert(
    type(relativePath) == "string" and relativePath:sub(1, 1) ~= "/" and relativePath:sub(1, 2) ~= "..",
    "repo fs paths are repo-relative"
  )
  return self._root .. "/" .. relativePath
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
