-- Public entry point of the capability-aware test runner: recursive discovery
-- over approved roots, layer/filter selection, and explicit pass/fail/skip
-- results. There is no module registry — a suite is discovered because it
-- exists, so removing a line can never hide a test.
--
-- Options:
--   roots        RunnerRoot[]                 required; { path, prefix, layer }
--   fs           love.filesystem-shaped       defaults to love.filesystem
--   load         fun(moduleName): table       defaults to require
--   capabilities table<string, boolean>       available capabilities, default {}
--   layer        string|nil                   run only this layer
--   filter       string|nil                   substring or Lua pattern over
--                                             "module :: test"

local Discovery = require("tests.runner.Discovery")
local Execution = require("tests.runner.Execution")
local Selection = require("tests.runner.Selection")
local Suite = require("tests.runner.Suite")

local TestRunner = {}

local function resolve(options)
  assert(type(options) == "table", "TestRunner needs an options table")
  local fs = options.fs or (love ~= nil and love.filesystem or nil)
  assert(type(fs) == "table", "TestRunner needs a filesystem reader")
  return {
    roots = options.roots,
    fs = fs,
    load = options.load or require,
    capabilities = options.capabilities or {},
    layer = options.layer,
    filter = options.filter,
  }
end

local function loadFailure(entry, message)
  return {
    module = entry.module,
    test = "<load>",
    status = "fail",
    message = message,
    layer = entry.layer,
    duration = 0,
  }
end

-- Discovers and normalizes every suite of the selected layer, in module order.
-- Loads modules (test names come from the module itself) but never executes a
-- test body. Each returned item carries either a normalized `suite` or the
-- `failure` result of a module that could not be loaded or normalized.
---@return { suite: RunnerSuite|nil, failure: table|nil }[]
local function collect(config)
  local items = {}
  for _, entry in ipairs(Discovery.suites(config.fs, config.roots)) do
    if Selection.matchesLayer(entry.layer, config.layer) then
      local ok, loaded = pcall(config.load, entry.module)
      if not ok then
        items[#items + 1] = { failure = loadFailure(entry, "module load failed: " .. tostring(loaded)) }
      else
        local normalized
        ok, normalized = pcall(Suite.normalize, loaded, entry.module, entry.layer)
        if not ok then
          items[#items + 1] = { failure = loadFailure(entry, tostring(normalized)) }
        elseif Selection.matchesLayer(normalized.layer, config.layer) then
          items[#items + 1] = { suite = normalized }
        end
      end
    end
  end
  return items
end

-- Discovery without execution: one entry per suite, sorted by module name.
---@return { module: string, layer: string, capabilities: string[], tags: string[], tests: string[] }[]
function TestRunner.list(options)
  local config = resolve(options)
  local listing = {}
  for _, item in ipairs(collect(config)) do
    if item.failure ~= nil then
      error(item.failure.message, 0)
    end
    local suite = assert(item.suite, "collected item carries neither a suite nor a failure")
    local tests = Selection.tests(suite, config.filter)
    if #tests > 0 or config.filter == nil then
      listing[#listing + 1] = {
        module = suite.module,
        layer = suite.layer,
        capabilities = suite.capabilities,
        tags = suite.tags,
        tests = tests,
      }
    end
  end
  return listing
end

local function tally(run, entry)
  run.results[#run.results + 1] = entry
  local layer = run.byLayer[entry.layer]
  if layer == nil then
    layer = { passed = 0, failed = 0, skipped = 0, duration = 0 }
    run.byLayer[entry.layer] = layer
  end
  layer.duration = layer.duration + entry.duration
  if entry.status == "pass" then
    run.passed = run.passed + 1
    layer.passed = layer.passed + 1
  elseif entry.status == "skip" then
    run.skipped = run.skipped + 1
    layer.skipped = layer.skipped + 1
  else
    run.failed = run.failed + 1
    layer.failed = layer.failed + 1
  end
end

---@class RunnerRun
---@field results table[]
---@field passed integer
---@field failed integer
---@field skipped integer
---@field duration number seconds
---@field byLayer table<string, { passed: integer, failed: integer, skipped: integer, duration: number }>
---@field capabilities table<string, boolean>

---@return RunnerRun
function TestRunner.run(options)
  local config = resolve(options)
  local started = love ~= nil and love.timer ~= nil and love.timer.getTime() or os.clock()
  local items = collect(config)

  local run = {
    results = {},
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 0,
    byLayer = {},
    capabilities = config.capabilities,
  }
  for _, item in ipairs(items) do
    if item.failure ~= nil then
      tally(run, item.failure)
    else
      local suite = assert(item.suite, "collected item carries neither a suite nor a failure")
      for _, entry in ipairs(Execution.runSuite(suite, config)) do
        tally(run, entry)
      end
    end
  end

  local finished = love ~= nil and love.timer ~= nil and love.timer.getTime() or os.clock()
  run.duration = finished - started
  return run
end

return TestRunner
