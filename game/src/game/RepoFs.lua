-- Repo-filesystem adapter for the script override system: reads checked-in
-- content under the repository root (e.g. `data/scripts/overrides`) that
-- lives outside the LÖVE source and save directories. The LÖVE build's
-- love.filesystem.mount cannot attach host directories, so this adapter uses
-- plain io (the repo root comes from love.filesystem.getSourceBaseDirectory
-- at construction). It implements the directory-shaped contract the script
-- loader consumes (colon-style getDirectoryItems + read). Interface layer:
-- never imported by domain modules.

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

---@param path string
---@return string[]
function RepoFs:getDirectoryItems(path)
  local pipe = io.popen("ls -1 " .. self:_full(path) .. " 2>/dev/null")
  if not pipe then
    return {}
  end
  local output = pipe:read("*a")
  pipe:close()
  local names = {}
  for name in output:gmatch("[^\n]+") do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

return RepoFs
