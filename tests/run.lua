-- Aggregate entry point of the test suite, invoked via `love game/ --test`
-- (`scripts/test.sh`). It owns only the approved discovery roots and their
-- default layers plus the wiring of argument parsing, capability detection,
-- execution, and reporting; those live in `tests/runner/`. There is no module
-- registry: a suite runs because the file exists.

local Capabilities = require("tests.runner.Capabilities")
local Cli = require("tests.runner.Cli")
local RepoFiles = require("tests.runner.RepoFiles")
local Report = require("tests.runner.Report")
local TestRunner = require("tests.runner.TestRunner")

-- The process environment, read lazily. Passed explicitly into the pure command
-- modules so their behavior never depends on an ambient lookup.
local ENV = setmetatable({}, {
  __index = function(_, name)
    return os.getenv(name)
  end,
})

---@type RunnerRoot[]
local ROOTS = {
  { path = "libs/rom/tests", prefix = "libs.rom.tests", layer = "unit" },
  { path = "libs/math/tests", prefix = "libs.math.tests", layer = "unit" },
  { path = "libs/assets/tests", prefix = "libs.assets.tests", layer = "unit" },
  { path = "libs/engine/tests", prefix = "libs.engine.tests", layer = "unit" },
  { path = "game/tests", prefix = "game.tests", layer = "component" },
  { path = "romdump/tests", prefix = "romdump.tests", layer = "component" },
  { path = "tests/runner/tests", prefix = "tests.runner.tests", layer = "unit" },
  { path = "tests/rom", prefix = "tests.rom", layer = "rom" },
  { path = "tests/acceptance", prefix = "tests.acceptance", layer = "acceptance" },
}

-- `options` accepts `layer`, `filter`, and `capabilities`; `main` parses them
-- out of the argv.
---@param options table|nil
local function runnerOptions(options)
  options = options or {}
  local paths = {}
  for _, root in ipairs(ROOTS) do
    paths[#paths + 1] = root.path
  end
  return {
    roots = ROOTS,
    fs = RepoFiles.new(love.filesystem.getSourceBaseDirectory(), paths),
    capabilities = options.capabilities,
    layer = options.layer,
    filter = options.filter,
  }
end

-- Discovery without execution, for `--list`.
---@param options table|nil
---@return table[] listing
local function list(options)
  return TestRunner.list(runnerOptions(options))
end

-- The whole command: parse, detect capabilities, run or list, report, and
-- return the process exit status.
---@param argv string[]
---@return integer exitCode
local function main(argv)
  local plan, message = Cli.parse(argv, { env = ENV })
  if plan == nil then
    io.stderr:write("test: " .. tostring(message) .. "\n")
    return Cli.EXIT_USAGE
  end

  local capabilities, versions = Capabilities.detect({ env = ENV })
  if plan.romSource ~= nil then
    -- The shell entrypoint imported and built that source into an isolated save
    -- root before this run; parsing already proved the path readable.
    capabilities.rom_source = true
  end

  if plan.list then
    print(table.concat(Report.listingLines(list(plan)), "\n"))
    return 0
  end

  local result = TestRunner.run(runnerOptions({
    capabilities = capabilities,
    layer = plan.layer,
    filter = plan.filter,
  }))
  result.versions = versions
  print(table.concat(Report.lines(result), "\n"))

  -- Flush first so the warning banner cannot land inside the buffered report.
  io.stdout:flush()

  local outcome = Cli.outcome(plan, capabilities, result)
  if outcome.warning ~= nil then
    io.stderr:write(outcome.warning .. "\n")
  end
  if outcome.failure ~= nil then
    io.stderr:write("test: " .. outcome.failure .. "\n")
  end
  return outcome.exitCode
end

return { main = main, list = list, ROOTS = ROOTS }
