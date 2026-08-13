-- Recursive discovery of test suites beneath approved roots. Pure: the only
-- filesystem access goes through the injected `fs` (a love.filesystem-shaped
-- table exposing `getDirectoryItems` and `getInfo`), so the runner's own tests
-- drive it with a fake corpus.
--
-- A file is a suite exactly when its name ends in `_test.lua`. The repository
-- controls every suite filename, so the former plural `_tests.lua` spelling
-- is not discovered. Results are sorted by module name so execution order
-- never depends on filesystem order, and a module name reachable twice is an
-- error rather than a silently doubled or dropped suite.

local Discovery = {}

---@class RunnerRoot
---@field path string repo-relative directory to walk
---@field prefix string dotted module prefix for files under `path`
---@field layer string default layer for suites discovered here

local function isSuiteFile(name)
  return name:match("_test%.lua$") ~= nil
end

local function walk(fs, path, prefix, layer, out)
  local entries = fs.getDirectoryItems(path)
  table.sort(entries)
  for _, entry in ipairs(entries) do
    local childPath = path .. "/" .. entry
    local info = fs.getInfo(childPath)
    if info ~= nil and info.type == "directory" then
      walk(fs, childPath, prefix .. "." .. entry, layer, out)
    elseif isSuiteFile(entry) then
      out[#out + 1] = { module = prefix .. "." .. entry:sub(1, -5), layer = layer, path = childPath }
    end
  end
end

-- Every suite beneath `roots`, sorted by module name.
---@param fs table love.filesystem-shaped reader
---@param roots RunnerRoot[]
---@return { module: string, layer: string, path: string }[]
function Discovery.suites(fs, roots)
  assert(type(roots) == "table" and #roots > 0, "discovery needs at least one root")
  local found = {}
  for _, root in ipairs(roots) do
    assert(type(root.path) == "string" and type(root.prefix) == "string", "root needs path and prefix")
    assert(type(root.layer) == "string", "root needs a default layer: " .. root.path)
    walk(fs, root.path, root.prefix, root.layer, found)
  end

  local byModule = {}
  for _, suite in ipairs(found) do
    local previous = byModule[suite.module]
    if previous ~= nil then
      error("duplicate test module " .. suite.module .. " (" .. previous.path .. " and " .. suite.path .. ")", 0)
    end
    byModule[suite.module] = suite
  end

  table.sort(found, function(a, b)
    return a.module < b.module
  end)
  return found
end

return Discovery
