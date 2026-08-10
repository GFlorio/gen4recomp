-- Contract tests for run reporting: the report must say what actually ran.
-- Skips are visible with their reason (a skipped suite must never read as a
-- silent success), counts are broken down per layer, and slow tests are named.

local Assert = require("tests.support.Assert")
local Report = require("tests.runner.Report")

local T = {}

local function contains(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function run(results, overrides)
  local out = {
    results = results,
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 1.5,
    byLayer = {},
    capabilities = {},
  }
  for key, value in pairs(overrides or {}) do
    out[key] = value
  end
  return out
end

function T.skips_are_reported_with_reason_and_counts()
  local lines = Report.lines(run({
    {
      module = "tests.rom.dump_test",
      test = "reads the dump",
      status = "skip",
      message = "missing capability: rom_dump",
      layer = "rom",
      duration = 0,
    },
  }, {
    skipped = 1,
    byLayer = { rom = { passed = 0, failed = 0, skipped = 1, duration = 0 } },
  }))

  Assert.isTrue(contains(lines, "SKIP tests.rom.dump_test :: reads the dump"), "names the skipped test")
  Assert.isTrue(contains(lines, "missing capability: rom_dump"), "keeps the skip reason")
  Assert.isTrue(contains(lines, "0 passed, 0 failed, 1 skipped"), "counts the skip")
  Assert.isTrue(contains(lines, "rom"), "breaks counts down by layer")
end

function T.failures_are_detailed_with_the_slowest_one_named()
  local lines = Report.lines(run({
    {
      module = "libs.rom.tests.a_test",
      test = "quick",
      status = "fail",
      message = "boom quick",
      layer = "unit",
      duration = 0.01,
    },
    {
      module = "libs.rom.tests.b_test",
      test = "slow",
      status = "fail",
      message = "boom slow",
      layer = "unit",
      duration = 0.5,
    },
  }, {
    failed = 2,
    byLayer = { unit = { passed = 0, failed = 2, skipped = 0, duration = 0.51 } },
  }))

  Assert.isTrue(contains(lines, "FAIL libs.rom.tests.a_test :: quick"), "names each failure")
  Assert.isTrue(contains(lines, "boom slow"), "keeps failure messages")
  Assert.isTrue(contains(lines, "slowest failing: libs.rom.tests.b_test :: slow"), "names the slowest failure")
  Assert.isFalse(contains(lines, "slowest 1:"), "no slowest-five list while red")
end

function T.green_run_lists_the_slowest_passing_tests_and_capabilities()
  local results = {}
  for index = 1, 6 do
    results[index] = {
      module = "libs.rom.tests.a_test",
      test = "case " .. index,
      status = "pass",
      layer = "unit",
      duration = index / 100,
    }
  end

  local lines = Report.lines(run(results, {
    passed = 6,
    byLayer = { unit = { passed = 6, failed = 0, skipped = 0, duration = 0.21 } },
    capabilities = { graphics = true, rom_dump = true },
  }))

  Assert.isTrue(contains(lines, "slowest 1: libs.rom.tests.a_test :: case 6"), "slowest first")
  Assert.isTrue(contains(lines, "slowest 5: libs.rom.tests.a_test :: case 2"), "five entries")
  Assert.isFalse(contains(lines, "slowest 6:"), "at most five entries")
  Assert.isTrue(contains(lines, "capabilities: graphics, rom_dump"), "names detected capabilities")
end

-- `--list` shows what would run without executing it, including the metadata a
-- reader needs to select a layer, and does not hide a module that failed to load.
function T.listing_shows_layer_capabilities_tags_and_broken_modules()
  local lines = Report.listingLines({
    {
      module = "tests.rom.new_bark_test",
      layer = "rom",
      capabilities = { "rom_dump" },
      tags = { "field" },
      tests = { "warps home", "reads terrain" },
    },
    { module = "tests.rom.broken_test", layer = "rom", capabilities = {}, tags = {}, tests = {}, error = "boom" },
  })

  Assert.isTrue(contains(lines, "tests.rom.new_bark_test"), "names the module")
  Assert.isTrue(contains(lines, "rom"), "names the layer")
  Assert.isTrue(contains(lines, "rom_dump"), "names the capabilities")
  Assert.isTrue(contains(lines, "field"), "names the tags")
  Assert.isTrue(contains(lines, "2 tests"), "counts the tests")
  Assert.isTrue(contains(lines, "boom"), "a broken module is listed with its load error")
  Assert.isTrue(contains(lines, "2 suites"), "totals the listing")
end

return T
