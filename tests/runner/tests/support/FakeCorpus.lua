-- Declarative fake test corpus for the runner's self-tests. Maps repo-relative
-- file paths to module tables (or the LOAD_ERROR marker) and exposes a
-- love.filesystem-shaped reader plus a module loader, so discovery, selection,
-- and execution are testable without touching disk, LÖVE, a ROM dump, or a GPU.
--
-- Module names are the dotted file path without the ".lua" suffix.

local RepoFiles = require("tests.runner.RepoFiles")

local FakeCorpus = {}
FakeCorpus.__index = FakeCorpus

-- Placed as a file's value to make `load` raise for that module.
FakeCorpus.LOAD_ERROR = "FakeCorpus.LOAD_ERROR"

---@param files table<string, table|string> repo-relative path -> module table
---@return table corpus with `fs`, `load`, and `root(path, layer)`
function FakeCorpus.new(files)
  local self = setmetatable({ files = files }, FakeCorpus)
  local paths = {}
  for path in pairs(files) do
    paths[path] = true
  end
  local reader = RepoFiles.fromFileSet(paths)
  self.fs = {
    -- Deliberately reverse alphabetical: a runner that trusts filesystem order
    -- instead of sorting cannot pass the ordering test.
    getDirectoryItems = function(path)
      local entries = reader.getDirectoryItems(path)
      table.sort(entries, function(a, b)
        return a > b
      end)
      return entries
    end,
    getInfo = reader.getInfo,
  }
  self.load = function(moduleName)
    return self:_load(moduleName)
  end
  return self
end

-- Focused root descriptor for the runner's test-only `roots` option.
function FakeCorpus:root(path, layer)
  return { path = path, layer = layer }
end

function FakeCorpus:_load(moduleName)
  local path = moduleName:gsub("%.", "/") .. ".lua"
  local mod = self.files[path]
  if mod == nil then
    error("module '" .. moduleName .. "' not found in fake corpus", 0)
  end
  if mod == FakeCorpus.LOAD_ERROR then
    error(path .. ":1: fake load failure", 0)
  end
  return mod
end

return FakeCorpus
