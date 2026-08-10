-- Aggregate entry point of the public test suite, invoked via `love game/
-- --test`. It owns only the approved discovery roots and their default layers;
-- discovery, selection, execution, and reporting live in `tests/runner/`. There
-- is no module registry: a suite runs because the file exists.

local RepoFiles = require("tests.runner.RepoFiles")
local Report = require("tests.runner.Report")
local TestRunner = require("tests.runner.TestRunner")

---@type RunnerRoot[]
local ROOTS = {
  { path = "libs/rom/tests", prefix = "libs.rom.tests", layer = "unit" },
  { path = "libs/math/tests", prefix = "libs.math.tests", layer = "unit" },
  { path = "libs/assets/tests", prefix = "libs.assets.tests", layer = "unit" },
  { path = "libs/engine/tests", prefix = "libs.engine.tests", layer = "unit" },
  { path = "game/tests", prefix = "game.tests", layer = "component" },
  { path = "romdump/tests", prefix = "romdump.tests", layer = "component" },
  { path = "tests/runner/tests", prefix = "tests.runner.tests", layer = "unit" },
}

-- `options` accepts `layer`, `filter`, and `capabilities`; the shell entrypoint
-- owns their parsing.
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

---@param options table|nil
---@return integer failed test count
local function run(options)
  local result = TestRunner.run(runnerOptions(options))
  print(table.concat(Report.lines(result), "\n"))
  return result.failed
end

-- Discovery without execution, for `--list`.
---@param options table|nil
---@return table[] listing
local function list(options)
  return TestRunner.list(runnerOptions(options))
end

return { run = run, list = list, ROOTS = ROOTS }
