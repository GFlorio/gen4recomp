-- Contract tests for the capability-aware runner's discovery, listing, and
-- selection. Discovery is recursive over approved roots and is the only source
-- of truth: no hand-maintained module registry may exist. Listing reports
-- layer/capability metadata without executing any test body.
--
-- Suffix rule under test: a file is a suite when its name ends in `_test.lua`
-- or its plural `_tests.lua` (the existing `libs/engine/tests/script/*_tests.lua`
-- suites must be discoverable without renaming).

local Assert = require("tests.support.Assert")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

local function legacy(names)
  local mod = {}
  for _, name in ipairs(names) do
    mod[name] = function() end
  end
  return mod
end

local function moduleNames(listing)
  local out = {}
  for _, suite in ipairs(listing) do
    out[#out + 1] = suite.module
  end
  return out
end

-- Raises when absent so a missing suite fails as a listing defect rather than
-- as a nil index further down the test.
---@return { module: string, layer: string, capabilities: string[], tags: string[], tests: string[] }
local function find(listing, moduleName)
  for _, suite in ipairs(listing) do
    if suite.module == moduleName then
      return suite
    end
  end
  error("listing has no suite " .. moduleName, 2)
end

-- nested suites are discovered; non-suite files are not.
function T.discovery_finds_nested_suites_and_ignores_other_files()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = legacy({ "a" }),
    ["fake/unit/nested/deep/beta_tests.lua"] = legacy({ "b" }),
    ["fake/unit/support/Helper.lua"] = {},
    ["fake/unit/nested/notes.md"] = {},
  })

  local listing = TestRunner.list({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.deepEqual(moduleNames(listing), { "fake.unit.alpha_test", "fake.unit.nested.deep.beta_tests" })
end

-- order is deterministic and independent of filesystem order.
function T.discovery_order_is_sorted_not_filesystem_order()
  local corpus = FakeCorpus.new({
    ["fake/unit/zulu_test.lua"] = legacy({ "z second", "a first" }),
    ["fake/unit/alpha_test.lua"] = legacy({ "only" }),
    ["fake/unit/mike_test.lua"] = legacy({ "only" }),
  })
  local options = { roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load }

  local listing = TestRunner.list(options)

  Assert.deepEqual(moduleNames(listing), { "fake.unit.alpha_test", "fake.unit.mike_test", "fake.unit.zulu_test" })
  Assert.deepEqual(find(listing, "fake.unit.zulu_test").tests, { "a first", "z second" })
  Assert.deepEqual(moduleNames(TestRunner.list(options)), moduleNames(listing))
end

-- a module name reachable from two roots is a hard error, not a
-- silently doubled or dropped suite.
function T.duplicate_module_name_is_rejected()
  local corpus = FakeCorpus.new({ ["fake/unit/alpha_test.lua"] = legacy({ "a" }) })
  local root = corpus:root("fake/unit", "unit")

  local err = Assert.throws(function()
    TestRunner.list({ roots = { root, root }, fs = corpus.fs, load = corpus.load })
  end)

  Assert.isTrue(
    tostring(err):find("fake.unit.alpha_test", 1, true) ~= nil,
    "error names the duplicate module: " .. tostring(err)
  )
end

-- listing the corpus never runs a test body.
function T.listing_does_not_execute_test_bodies()
  local executed = false
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      ["explodes when executed"] = function()
        executed = true
        error("test body must not run during --list", 0)
      end,
    },
  })

  local listing = TestRunner.list({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(#listing, 1)
  Assert.deepEqual(listing[1].tests, { "explodes when executed" })
  Assert.isFalse(executed, "listing executed a test body")
end

-- explicit metadata is surfaced; legacy modules default their layer
-- from the root they were discovered under, and declare no capabilities.
function T.listing_reports_layer_capabilities_and_tags()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = legacy({ "a" }),
    ["fake/acc/lab_test.lua"] = {
      metadata = { layer = "acceptance", capabilities = { "rom_dump", "derived_cache" }, tags = { "field" } },
      beforeAll = function() end,
      afterAll = function() end,
      tests = { ["lab exit round trip"] = function() end },
    },
  })

  local listing = TestRunner.list({
    roots = { corpus:root("fake/acc", "acceptance"), corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
  })

  local unit = find(listing, "fake.unit.alpha_test")
  Assert.equal(unit.layer, "unit")
  Assert.deepEqual(unit.capabilities, {})
  local acceptance = find(listing, "fake.acc.lab_test")
  Assert.equal(acceptance.layer, "acceptance")
  Assert.deepEqual(acceptance.capabilities, { "rom_dump", "derived_cache" })
  Assert.deepEqual(acceptance.tags, { "field" })
  -- metadata/beforeAll/afterAll keys are not tests
  Assert.deepEqual(acceptance.tests, { "lab exit round trip" })
end

-- layer selection runs only the selected layer.
function T.layer_selection_runs_only_that_layer()
  local ran = {}
  local function record(label)
    return function()
      ran[#ran + 1] = label
    end
  end
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { ["unit case"] = record("unit") },
    ["fake/gfx/shader_test.lua"] = {
      metadata = { layer = "graphics" },
      tests = { ["graphics case"] = record("graphics") },
    },
  })
  local options = {
    roots = { corpus:root("fake/gfx", "graphics"), corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
  }

  options.layer = "unit"
  local result = TestRunner.run(options)

  Assert.deepEqual(ran, { "unit" })
  Assert.equal(result.passed, 1)
  Assert.equal(result.failed, 0)
  Assert.equal(result.skipped, 0)
end

-- filter matches against the fully qualified module :: test name.
function T.filter_matches_qualified_module_and_test_name()
  local corpus = FakeCorpus.new({
    ["fake/unit/warp_test.lua"] = { ["resolves door"] = function() end, ["resolves stairs"] = function() end },
    ["fake/unit/camera_test.lua"] = { ["resolves door"] = function() end, ["pans"] = function() end },
  })
  local roots = { corpus:root("fake/unit", "unit") }

  local byModule = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "warp_test" })
  Assert.equal(byModule.passed, 2)

  local byTest = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "pans" })
  Assert.equal(byTest.passed, 1)

  local byBoth = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "resolves door" })
  Assert.equal(byBoth.passed, 2)
end

return T
