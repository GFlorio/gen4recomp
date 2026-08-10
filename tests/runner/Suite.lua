-- Normalizes a loaded test module into one suite shape. Two module shapes are
-- accepted:
--
--   legacy:   { ["test name"] = function(context) end, ... }
--   explicit: { metadata = { layer, capabilities, tags },
--               beforeAll = f, afterAll = f, tests = { ... } }
--
-- A legacy module inherits the layer of the root it was discovered under and
-- declares no capabilities. Metadata/hook keys are never treated as tests.

local Suite = {}

local METADATA_KEYS = { layer = true, capabilities = true, tags = true }
local MODULE_KEYS = { metadata = true, beforeAll = true, afterAll = true, tests = true }

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function stringArray(value, what, moduleName)
  if value == nil then
    return {}
  end
  assert(type(value) == "table", moduleName .. ": metadata." .. what .. " must be an array")
  local out = {}
  for index, entry in ipairs(value) do
    assert(type(entry) == "string", moduleName .. ": metadata." .. what .. "[" .. index .. "] must be a string")
    out[index] = entry
  end
  return out
end

local function isExplicit(mod)
  return mod.tests ~= nil or mod.metadata ~= nil or mod.beforeAll ~= nil or mod.afterAll ~= nil
end

---@class RunnerSuite
---@field module string
---@field layer string
---@field capabilities string[]
---@field tags string[]
---@field tests string[] sorted test names
---@field fns table<string, fun(context: table)>
---@field beforeAll fun(context: table)|nil
---@field afterAll fun(context: table)|nil

-- Raises when the module violates the suite contract; the caller reports that
-- as a failed result for `moduleName`.
---@param mod table loaded test module
---@param moduleName string
---@param defaultLayer string layer of the discovery root
---@return RunnerSuite
function Suite.normalize(mod, moduleName, defaultLayer)
  assert(type(mod) == "table", moduleName .. ": test module must return a table")

  local fns, metadata
  if isExplicit(mod) then
    for _, key in ipairs(sortedKeys(mod)) do
      assert(MODULE_KEYS[key], moduleName .. ": unknown suite key '" .. key .. "'")
    end
    assert(type(mod.tests) == "table", moduleName .. ": suite needs a tests table")
    fns = mod.tests
    metadata = mod.metadata or {}
    assert(type(metadata) == "table", moduleName .. ": metadata must be a table")
    for _, key in ipairs(sortedKeys(metadata)) do
      assert(METADATA_KEYS[key], moduleName .. ": unknown metadata key '" .. key .. "'")
    end
  else
    fns = mod
    metadata = {}
  end

  local names = sortedKeys(fns)
  for _, name in ipairs(names) do
    assert(type(fns[name]) == "function", moduleName .. ": test '" .. name .. "' must be a function")
  end

  local layer = metadata.layer or defaultLayer
  assert(type(layer) == "string", moduleName .. ": metadata.layer must be a string")

  return {
    module = moduleName,
    layer = layer,
    capabilities = stringArray(metadata.capabilities, "capabilities", moduleName),
    tags = stringArray(metadata.tags, "tags", moduleName),
    tests = names,
    fns = fns,
    beforeAll = mod.beforeAll,
    afterAll = mod.afterAll,
  }
end

return Suite
