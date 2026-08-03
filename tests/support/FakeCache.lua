-- In-memory CacheFs backend for tests. Operates on save-directory-relative
-- full paths (already version-prefixed by CacheFs). Directories are implied by
-- file paths, plus any explicitly created empty directories.

local FakeCache = {}
FakeCache.__index = FakeCache

function FakeCache.new()
  return setmetatable({ files = {}, dirs = {} }, FakeCache)
end

function FakeCache:write(path, data)
  self.files[path] = data
  return true
end

function FakeCache:read(path)
  return self.files[path]
end

local function hasChildren(self, path)
  local prefix = path .. "/"
  for k in pairs(self.files) do
    if k:sub(1, #prefix) == prefix then return true end
  end
  for k in pairs(self.dirs) do
    if k:sub(1, #prefix) == prefix then return true end
  end
  return false
end

function FakeCache:getInfo(path)
  if self.files[path] ~= nil then
    return { type = "file", size = #self.files[path] }
  end
  if self.dirs[path] or hasChildren(self, path) then
    return { type = "directory" }
  end
  return nil
end

function FakeCache:createDirectory(path)
  self.dirs[path] = true
  return true
end

function FakeCache:remove(path)
  self.files[path] = nil
  self.dirs[path] = nil
  return true
end

function FakeCache:getDirectoryItems(path)
  local prefix = path .. "/"
  local seen, names = {}, {}
  local function consider(k)
    if k:sub(1, #prefix) == prefix then
      local rest = k:sub(#prefix + 1)
      local name = rest:match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  for k in pairs(self.files) do consider(k) end
  for k in pairs(self.dirs) do consider(k) end
  table.sort(names)
  return names
end

return FakeCache
