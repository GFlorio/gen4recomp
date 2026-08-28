-- Pure selection rules: which suites and tests a run executes, and which
-- declared capability (if any) is unavailable.
--
-- A filter is matched literally against the fully qualified `module :: test`
-- name, so a module name, a test name, or any substring spanning both
-- selects. Lua pattern metacharacters have no special meaning.

local Selection = {}

Selection.QUALIFIER = " :: "

---@param moduleName string
---@param testName string
---@return string fully qualified test name used for filtering and reporting
function Selection.qualify(moduleName, testName)
  return moduleName .. Selection.QUALIFIER .. testName
end

---@param qualified string
---@param filter string|nil nil selects every test
---@return boolean
function Selection.matchesFilter(qualified, filter)
  if filter == nil then
    return true
  end
  return qualified:find(filter, 1, true) ~= nil
end

-- The first declared capability that is unavailable, or nil when the suite can
-- run. Order follows the declaration so the reported reason is stable.
---@param capabilities string[]
---@param available table<string, boolean>
---@return string|nil
function Selection.missingCapability(capabilities, available)
  for _, name in ipairs(capabilities) do
    if available[name] ~= true then
      return name
    end
  end
  return nil
end

-- The selected test names of one suite, in the suite's (sorted) order.
---@param suite RunnerSuite
---@param filter string|nil
---@return string[]
function Selection.tests(suite, filter)
  local out = {}
  for _, name in ipairs(suite.tests) do
    if Selection.matchesFilter(Selection.qualify(suite.module, name), filter) then
      out[#out + 1] = name
    end
  end
  return out
end

return Selection
