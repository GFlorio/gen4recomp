-- Contract tests for the capability-aware runner's execution and result model
-- (spec deliverable 4; scenario IDs RUNNER-08..RUNNER-15). Results are pass,
-- fail, or skip: a skip is always explicit and is never counted as a pass, a
-- module-load error is a failed result carrying the module name rather than a
-- runner crash, and cleanup hooks run on every terminal path.

local Assert = require("tests.support.Assert")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

-- Raises when absent so a missing result fails as a reporting defect rather
-- than as a nil index further down the test.
---@return { module: string, test: string, status: string, message: string, layer: string, duration: number }
local function resultFor(run, moduleName, testName)
  for _, entry in ipairs(run.results) do
    if entry.module == moduleName and (testName == nil or entry.test == testName) then
      return entry
    end
  end
  error("no result for " .. moduleName .. " :: " .. tostring(testName), 2)
end

-- RUNNER-08: legacy `name -> function` modules still run, with the layer taken
-- from the root they were discovered under.
function T.legacy_module_shape_runs_with_root_layer()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { ["adds"] = function() end, ["subtracts"] = function() end },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.passed, 2)
  Assert.equal(run.failed, 0)
  Assert.equal(run.skipped, 0)
  Assert.equal(resultFor(run, "fake.unit.alpha_test", "adds").status, "pass")
  Assert.equal(resultFor(run, "fake.unit.alpha_test", "adds").layer, "unit")
end

-- RUNNER-09: a module that fails to load is one failed result naming the
-- module; the rest of the corpus still runs.
function T.module_load_failure_is_a_failed_result()
  local corpus = FakeCorpus.new({
    ["fake/unit/broken_test.lua"] = FakeCorpus.LOAD_ERROR,
    ["fake/unit/healthy_test.lua"] = { ["works"] = function() end },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.failed, 1)
  Assert.equal(run.passed, 1)
  local failure = resultFor(run, "fake.unit.broken_test")
  Assert.equal(failure.status, "fail")
  Assert.isTrue(
    tostring(failure.message):find("fake load failure", 1, true) ~= nil,
    "load failure keeps the underlying error: " .. tostring(failure.message)
  )
end

-- RUNNER-10: an explicit skip is recorded as a skip with its reason, never as
-- a pass.
function T.explicit_skip_is_counted_as_skip()
  local corpus = FakeCorpus.new({
    ["fake/rom/dump_test.lua"] = {
      ["reads the dump"] = function(context)
        context:skip("no ready user-owned HGSS dump")
        error("skip must abort the test body", 0)
      end,
    },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/rom", "rom") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.skipped, 1)
  Assert.equal(run.passed, 0)
  Assert.equal(run.failed, 0)
  local skip = resultFor(run, "fake.rom.dump_test", "reads the dump")
  Assert.equal(skip.status, "skip")
  Assert.isTrue(
    tostring(skip.message):find("no ready user-owned HGSS dump", 1, true) ~= nil,
    "skip records its reason: " .. tostring(skip.message)
  )
end

-- RUNNER-11: a suite whose declared capability is unavailable skips with the
-- capability named, and its bodies never run.
function T.missing_capability_skips_the_suite()
  local executed = false
  local corpus = FakeCorpus.new({
    ["fake/acc/lab_test.lua"] = {
      metadata = { layer = "acceptance", capabilities = { "rom_dump" } },
      tests = {
        ["boots the lab"] = function()
          executed = true
        end,
      },
    },
  })

  local run = TestRunner.run({
    roots = { corpus:root("fake/acc", "acceptance") },
    fs = corpus.fs,
    load = corpus.load,
    capabilities = { graphics = true },
  })

  Assert.isFalse(executed, "a suite missing its capability must not execute")
  Assert.equal(run.skipped, 1)
  Assert.equal(run.passed, 0)
  Assert.equal(run.failed, 0)
  local skip = resultFor(run, "fake.acc.lab_test", "boots the lab")
  Assert.equal(skip.status, "skip")
  Assert.isTrue(
    tostring(skip.message):find("rom_dump", 1, true) ~= nil,
    "capability skip names the capability: " .. tostring(skip.message)
  )
end

-- RUNNER-12: setup failure is reported and still runs the cleanup hook.
function T.setup_failure_reports_and_still_runs_cleanup()
  local cleanups = 0
  local executed = false
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      beforeAll = function(context)
        context.store = {}
        error("alpha setup failed", 0)
      end,
      afterAll = function()
        cleanups = cleanups + 1
      end,
      tests = {
        ["never runs"] = function()
          executed = true
        end,
      },
    },
    ["fake/unit/beta_test.lua"] = { ["still runs"] = function() end },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(cleanups, 1)
  Assert.isFalse(executed, "tests must not run after setup failed")
  Assert.equal(run.passed, 1)
  Assert.isTrue(run.failed >= 1, "setup failure is reported as a failure")
  local failure = resultFor(run, "fake.unit.alpha_test")
  Assert.equal(failure.status, "fail")
  Assert.isTrue(
    tostring(failure.message):find("alpha setup failed", 1, true) ~= nil,
    "setup failure keeps its message: " .. tostring(failure.message)
  )
end

-- RUNNER-13: one failing test stops neither its siblings nor later modules, and
-- cleanup still runs.
function T.test_failure_does_not_stop_the_run()
  local cleanups = 0
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      afterAll = function()
        cleanups = cleanups + 1
      end,
      tests = {
        ["a passes"] = function() end,
        ["b fails"] = function()
          error("deliberate alpha failure", 0)
        end,
        ["c passes"] = function() end,
      },
    },
    ["fake/unit/beta_test.lua"] = { ["runs after a failure"] = function() end },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.passed, 3)
  Assert.equal(run.failed, 1)
  Assert.equal(cleanups, 1)
  Assert.equal(resultFor(run, "fake.unit.alpha_test", "c passes").status, "pass")
  Assert.equal(resultFor(run, "fake.unit.beta_test", "runs after a failure").status, "pass")
  local failure = resultFor(run, "fake.unit.alpha_test", "b fails")
  Assert.isTrue(
    tostring(failure.message):find("deliberate alpha failure", 1, true) ~= nil,
    "failure keeps its message: " .. tostring(failure.message)
  )
end

-- RUNNER-14: the context threads suite state and capability queries from setup
-- into every test of that suite.
function T.context_is_shared_between_hooks_and_tests()
  local seen = {}
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      metadata = { layer = "unit", capabilities = { "graphics" } },
      beforeAll = function(context)
        context.fixture = "prepared"
      end,
      tests = {
        ["sees setup state"] = function(context)
          seen.fixture = context.fixture
          seen.graphics = context:hasCapability("graphics")
          seen.romDump = context:hasCapability("rom_dump")
        end,
      },
    },
  })

  local run = TestRunner.run({
    roots = { corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
    capabilities = { graphics = true },
  })

  Assert.equal(run.passed, 1)
  Assert.equal(seen.fixture, "prepared")
  Assert.isTrue(seen.graphics, "declared available capability reads as available")
  Assert.isFalse(seen.romDump, "undeclared capability reads as unavailable")
end

-- RUNNER-15: the report carries durations and per-layer pass/fail/skip counts.
function T.report_summarises_counts_and_durations_by_layer()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      ["passes"] = function() end,
      ["fails"] = function()
        error("deliberate failure", 0)
      end,
    },
    ["fake/rom/dump_test.lua"] = {
      metadata = { layer = "rom", capabilities = { "rom_dump" } },
      tests = { ["reads the dump"] = function() end },
    },
  })

  local run = TestRunner.run({
    roots = { corpus:root("fake/rom", "rom"), corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
    capabilities = {},
  })

  Assert.equal(run.byLayer.unit.passed, 1)
  Assert.equal(run.byLayer.unit.failed, 1)
  Assert.equal(run.byLayer.unit.skipped, 0)
  Assert.equal(run.byLayer.rom.passed, 0)
  Assert.equal(run.byLayer.rom.skipped, 1)
  Assert.equal(type(run.duration), "number")
  Assert.equal(type(resultFor(run, "fake.unit.alpha_test", "passes").duration), "number")
end

return T
