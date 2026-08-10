-- Pure formatting of a run result into report lines. Says what actually ran:
-- pass/fail/skip counts per layer, durations, the slowest tests, and the
-- capabilities the run had available. Never derives an exit status — the caller
-- owns that.

local Selection = require("tests.runner.Selection")

local Report = {}

local SLOWEST_WHEN_GREEN = 5

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function seconds(value)
  return string.format("%.2fs", value)
end

local function byDurationDescending(results)
  local sorted = {}
  for _, entry in ipairs(results) do
    sorted[#sorted + 1] = entry
  end
  table.sort(sorted, function(a, b)
    if a.duration == b.duration then
      return Selection.qualify(a.module, a.test) < Selection.qualify(b.module, b.test)
    end
    return a.duration > b.duration
  end)
  return sorted
end

local function withStatus(results, status)
  local out = {}
  for _, entry in ipairs(results) do
    if entry.status == status then
      out[#out + 1] = entry
    end
  end
  return out
end

-- Report lines for a completed run, in print order.
---@param run RunnerRun
---@return string[]
function Report.lines(run)
  local lines = {}
  local function add(line)
    lines[#lines + 1] = line
  end

  local failures = withStatus(run.results, "fail")
  local skips = withStatus(run.results, "skip")

  for _, entry in ipairs(failures) do
    add("FAIL " .. Selection.qualify(entry.module, entry.test) .. "\n    " .. tostring(entry.message))
  end
  for _, entry in ipairs(skips) do
    add("SKIP " .. Selection.qualify(entry.module, entry.test) .. " (" .. tostring(entry.message) .. ")")
  end

  add(
    string.format("%d passed, %d failed, %d skipped in %s", run.passed, run.failed, run.skipped, seconds(run.duration))
  )

  for _, layer in ipairs(sortedKeys(run.byLayer)) do
    local counts = run.byLayer[layer]
    add(
      string.format(
        "  %-12s %d passed, %d failed, %d skipped (%s)",
        layer,
        counts.passed,
        counts.failed,
        counts.skipped,
        seconds(counts.duration)
      )
    )
  end

  local capabilities = sortedKeys(run.capabilities or {})
  add("  capabilities: " .. (#capabilities > 0 and table.concat(capabilities, ", ") or "none"))

  if #failures > 0 then
    local slowestFailure = byDurationDescending(failures)[1]
    add(
      string.format(
        "  slowest failing: %s (%s)",
        Selection.qualify(slowestFailure.module, slowestFailure.test),
        seconds(slowestFailure.duration)
      )
    )
  else
    local slowest = byDurationDescending(withStatus(run.results, "pass"))
    for index = 1, math.min(SLOWEST_WHEN_GREEN, #slowest) do
      local entry = slowest[index]
      add(
        string.format(
          "  slowest %d: %s (%s)",
          index,
          Selection.qualify(entry.module, entry.test),
          seconds(entry.duration)
        )
      )
    end
  end

  return lines
end

return Report
