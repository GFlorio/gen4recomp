-- Contract tests for the single test-command surface. `scripts/test.sh` is the
-- only test entrypoint, so one Lua module owns argument parsing, capability
-- requirements, the loud missing-ROM warning, and the combined exit status.
--
-- The rules under test:
--   * invalid layer/filter/source arguments exit 2 and never start a run;
--   * a default run without a dump is green but loudly warned, with the exact
--     skipped counts of the ROM-gated layers;
--   * a run that *requires* a dump (--layer rom, --layer acceptance, strict
--     mode, --rom-source) is an infrastructure failure when it is absent, never
--     a skip-success;
--   * strict graphics mode (G4RECOMP_REQUIRE_GRAPHICS_TESTS) requires the
--     graphics capability when the selection includes the graphics layer, and
--     fails a whole-run selection that executed no graphics test;
--   * a failure in any layer, and a run that executed nothing at all, are
--     nonzero.

local Assert = require("tests.support.Assert")
local Cli = require("tests.runner.Cli")
local Report = require("tests.runner.Report")

local T = {}

local function contains(text, needle, label)
  Assert.isTrue(
    tostring(text):find(needle, 1, true) ~= nil,
    (label or "text") .. " must mention " .. string.format("%q", needle) .. ", got: " .. tostring(text)
  )
end

function T.test_entrypoint_runs_the_incremental_builder_for_real_dependency_freshness()
  local handle = assert(io.open("scripts/test.sh", "rb"))
  local script = handle:read("*a")
  handle:close()

  contains(script, "love romdump/ --build-cache", "test entrypoint")
  Assert.isNil(script:find("--check-derived-cache", 1, true))
end

function T.test_tooling_uses_run_scoped_temporary_directories()
  local handle = assert(io.open("scripts/test.sh", "rb"))
  local testScript = handle:read("*a")
  handle:close()

  handle = assert(io.open("scripts/lint.sh", "rb"))
  local lintScript = handle:read("*a")
  handle:close()

  contains(testScript, 'BUILD_LOG_DIR="$(mktemp -d)"', "test script")
  contains(lintScript, 'LUALS_LOG_DIR="$(mktemp -d)"', "lint script")
end

-- The shell must not re-implement option scanning: `scripts/test.sh` decides
-- whether to prepare the derived cache from the runner's machine-readable
-- plan response (`--plan`), not from a bash copy of the argument parser
-- coupled through exit codes.
function T.test_entrypoint_delegates_selection_to_the_runner()
  local handle = assert(io.open("scripts/test.sh", "rb"))
  local script = handle:read("*a")
  handle:close()

  contains(script, "--plan", "test entrypoint")
  Assert.isNil(script:find("rom_independent", 1, true), "no bash re-scan of --layer")
  Assert.isNil(script:find('case "${args[$index]}"', 1, true), "no bash option scanner")
end

-- Raises when parsing unexpectedly failed so a contract test fails on the
-- parser defect rather than on a nil index further down.
---@param argv string[]
---@param context table?
---@return TestPlan plan
local function parse(argv, context)
  local plan, message = Cli.parse(argv, context)
  Assert.isTrue(plan ~= nil, "expected a plan for " .. table.concat(argv, " ") .. ", got error: " .. tostring(message))
  return assert(plan)
end

---@param argv string[]
---@param context table?
---@return string
local function rejects(argv, context)
  local plan, message = Cli.parse(argv, context)
  Assert.isNil(plan, "expected no plan for: " .. table.concat(argv, " "))
  Assert.isTrue(type(message) == "string" and #message > 0, "a rejected argument list needs an actionable message")
  return assert(message)
end

local function hasCapability(plan, name)
  for _, required in ipairs(plan.requiredCapabilities) do
    if required == name then
      return true
    end
  end
  return false
end

-- The plan mode is part of the same command surface: it parses like any
-- other invocation, so the shell's plan lookup cannot drift from the run's
-- parsing.
function T.the_plan_mode_is_part_of_the_command_surface()
  local plan = parse({ "--plan" })
  Assert.isTrue(plan.planMode, "--plan marks the machine-readable plan mode")

  local combined = parse({ "--plan", "--layer", "unit" })
  Assert.isTrue(combined.planMode)
  Assert.equal(combined.layer, "unit")

  local listed = parse({ "--plan", "--list" })
  Assert.isTrue(listed.planMode)
  Assert.isTrue(listed.list)
end

-- The plan the shell consumes is a machine-readable answer, not a second
-- parser: whether the derived cache must be prepared (a supplied source is
-- always imported, whatever layer it is paired with) and the source path.
function T.the_plan_response_names_whether_the_cache_must_be_prepared()
  local function fields(argv, context)
    local lines = {}
    for _, line in ipairs(Cli.renderPlan(parse(argv, context))) do
      local key, value = line:match("^([^=]+)=(.*)$")
      Assert.notNil(key, "every plan line is key=value: " .. line)
      lines[key] = value
    end
    return lines
  end

  Assert.equal(fields({}).prepare, "1", "a default run must prepare the derived cache")
  Assert.equal(fields({ "--list" }).prepare, "0", "listing executes nothing")
  Assert.equal(fields({ "--layer", "unit" }).prepare, "0", "a ROM-independent layer skips preparation")
  Assert.equal(fields({ "--layer", "component" }).prepare, "0")
  Assert.equal(fields({ "--layer", "graphics" }).prepare, "0")
  Assert.equal(fields({ "--layer", "rom" }).prepare, "1", "a ROM-gated layer must prepare")
  Assert.equal(fields({ "--layer", "acceptance" }).prepare, "1")

  local context = {
    fileExists = function(path)
      return path == "/roms/hg.nds"
    end,
  }
  local sourced = fields({ "--layer", "unit", "--rom-source", "/roms/hg.nds" }, context)
  Assert.equal(sourced.prepare, "1", "a supplied source is always imported")
  Assert.equal(sourced.rom_source, "/roms/hg.nds", "the plan names the source path")
  Assert.isNil(fields({}, context).rom_source, "no source line when none was supplied")
end

-- A RunnerRun-shaped result. `layers` maps a layer name to its
-- passed/failed/skipped counts; totals and a matching `results` array are
-- derived so the same fixture drives both the exit policy and the report.
---@param layers table<string, { passed: integer|nil, failed: integer|nil, skipped: integer|nil }>
---@param extra table?
---@return RunnerRun
local function runOf(layers, extra)
  local run = {
    results = {},
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 0.5,
    byLayer = {},
    capabilities = {},
  }
  for layer, counts in pairs(layers) do
    local entry = { passed = counts.passed or 0, failed = counts.failed or 0, skipped = counts.skipped or 0 }
    entry.duration = 0.1
    run.byLayer[layer] = entry
    for _, status in ipairs({ "pass", "fail", "skip" }) do
      local field = status == "pass" and "passed" or (status == "fail" and "failed" or "skipped")
      for index = 1, entry[field] do
        run[field] = run[field] + 1
        run.results[#run.results + 1] = {
          module = layer .. "_" .. status .. "_test",
          test = status .. " " .. index,
          status = status,
          message = status == "pass" and "" or (status .. " reason"),
          layer = layer,
          duration = 0.01,
        }
      end
    end
  end
  for key, value in pairs(extra or {}) do
    run[key] = value
  end
  return run
end

local NO_DUMP = {}
local READY_DUMP = { rom_dump = true, derived_cache = true }

-- A bare run selects every layer, requires nothing, and tolerates the
-- `--test` mode flag it was dispatched with.
function T.default_plan_selects_every_layer_and_requires_nothing()
  for _, argv in ipairs({ {}, { "--test" } }) do
    local plan = parse(argv)
    Assert.isNil(plan.layer, "a default run is not restricted to one layer")
    Assert.isNil(plan.filter)
    Assert.isNil(plan.romSource)
    Assert.isFalse(plan.list)
    Assert.isFalse(plan.strict)
    Assert.deepEqual(plan.requiredCapabilities, {})
  end
end

-- Every documented option parses into the plan the runner consumes.
function T.documented_options_parse()
  Assert.equal(parse({ "--layer", "unit" }).layer, "unit")
  Assert.equal(parse({ "--layer", "graphics" }).layer, "graphics")
  Assert.equal(parse({ "--filter", "warp" }).filter, "warp")
  Assert.equal(parse({ "--filter", "^libs%.rom" }).filter, "^libs%.rom")
  Assert.isTrue(parse({ "--list" }).list)

  local combined = parse({ "--test", "--layer", "unit", "--filter", "resolves door" })
  Assert.equal(combined.layer, "unit")
  Assert.equal(combined.filter, "resolves door")

  local context = {
    fileExists = function(path)
      return path == "/roms/hg.nds"
    end,
  }
  local sourced = parse({ "--rom-source", "/roms/hg.nds" }, context)
  Assert.equal(sourced.romSource, "/roms/hg.nds")
  Assert.isTrue(hasCapability(sourced, "rom_source"), "--rom-source requires the rom_source capability")
end

-- Invalid layer/filter/source arguments are rejected before anything
-- runs, with the usage exit status.
function T.invalid_arguments_are_rejected_with_exit_two()
  Assert.equal(Cli.EXIT_USAGE, 2)

  local exists = {
    fileExists = function()
      return true
    end,
  }
  local missing = {
    fileExists = function()
      return false
    end,
  }

  contains(rejects({ "--layer" }), "--layer", "missing layer value")
  contains(rejects({ "--layer", "bogus" }), "bogus", "unknown layer")
  contains(rejects({ "--layer", "--filter", "warp" }), "--layer", "layer consuming the next flag")
  contains(rejects({ "--filter" }), "--filter", "missing filter value")
  contains(rejects({ "--filter", "" }), "--filter", "empty filter")
  contains(rejects({ "--rom-source" }, exists), "--rom-source", "missing source path")
  contains(rejects({ "--rom-source", "/no/such/rom.nds" }, missing), "/no/such/rom.nds", "unreadable source")
  contains(rejects({ "--layers", "unit" }), "--layers", "unknown option")
  contains(rejects({ "unit" }), "unit", "stray positional argument")
end

-- A filter is literal text, never a Lua pattern: metacharacters parse and
-- select literally instead of being diagnosed or interpreted.
function T.filter_metacharacters_are_literal_substrings()
  for _, filter in ipairs({ "(", "[", "%", "^libs%.rom", "warp" }) do
    Assert.equal(parse({ "--filter", filter }).filter, filter)
  end
end

-- Selecting a ROM-gated layer makes the dump mandatory.
function T.rom_gated_layers_require_the_dump()
  for _, layer in ipairs({ "rom", "acceptance" }) do
    local plan = parse({ "--layer", layer })
    Assert.equal(plan.layer, layer)
    Assert.isTrue(hasCapability(plan, "rom_dump"), "--layer " .. layer .. " must require rom_dump")
  end
  Assert.isFalse(hasCapability(parse({ "--layer", "unit" }), "rom_dump"))
end

-- Strict mode is environment-driven and makes the dump mandatory.
function T.strict_mode_comes_from_the_environment()
  local strict = parse({}, { env = { G4RECOMP_REQUIRE_ROM_TESTS = "1" } })
  Assert.isTrue(strict.strict)
  Assert.isTrue(hasCapability(strict, "rom_dump"), "strict mode must require rom_dump")

  local relaxed = parse({}, { env = { G4RECOMP_REQUIRE_ROM_TESTS = "0" } })
  Assert.isFalse(relaxed.strict)
  Assert.isFalse(hasCapability(relaxed, "rom_dump"))
  Assert.isFalse(parse({}, { env = {} }).strict)
end

-- With no dump, the default run stays green but says loudly what did
-- not run, with the exact skipped counts and both remediation commands.
function T.default_run_without_a_dump_is_green_and_loudly_warned()
  local plan = parse({})
  local run = runOf({
    unit = { passed = 1194 },
    component = { passed = 393 },
    graphics = { passed = 12 },
    rom = { skipped = 71 },
    acceptance = { skipped = 23 },
  })

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.equal(outcome.exitCode, 0, "executed tests all passed, so the run is green")
  Assert.isNil(outcome.failure, "a missing optional capability is not an infrastructure failure")
  Assert.notNil(outcome.warning, "a skipped ROM-gated layer must never pass silently")
  contains(outcome.warning, "71", "warning reports the skipped ROM-conformance count")
  contains(outcome.warning, "23", "warning reports the skipped acceptance count")
  contains(outcome.warning, "scripts/buildcache.sh", "warning names the remediation command")
  contains(outcome.warning, "G4RECOMP_REQUIRE_ROM_TESTS=1", "warning names the strict-mode command")
end

-- The banner reports what a selection actually lost: a selection that never
-- reached a ROM-gated layer is not warned, and a failing run still is.
function T.the_missing_dump_warning_follows_the_skips_not_the_status()
  local unitOnly = Cli.outcome(parse({ "--layer", "unit" }), NO_DUMP, runOf({ unit = { passed = 1194 } }))
  Assert.isNil(unitOnly.warning, "a selection with no ROM-gated skips has nothing to warn about")

  local failed = runOf({ unit = { passed = 1193, failed = 1 }, rom = { skipped = 71 } })
  local red = Cli.outcome(parse({}), NO_DUMP, failed)
  Assert.equal(red.exitCode, 1)
  Assert.notNil(red.warning, "a failure elsewhere must not hide the skipped ROM-gated layer")
end

-- With a ready dump nothing is skipped and nothing is warned about.
function T.ready_dump_run_is_green_without_a_warning()
  local run = runOf({ unit = { passed = 1194 }, rom = { passed = 71 }, acceptance = { passed = 23 } })

  local outcome = Cli.outcome(parse({}), READY_DUMP, run)

  Assert.equal(outcome.exitCode, 0)
  Assert.isNil(outcome.failure)
  Assert.isNil(outcome.warning, "a run with every layer executed has nothing to warn about")
end

-- Strict mode turns the missing dump into an actionable failure.
function T.strict_mode_without_a_dump_fails()
  local plan = parse({}, { env = { G4RECOMP_REQUIRE_ROM_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 }, rom = { skipped = 71 }, acceptance = { skipped = 23 } })

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.isTrue(outcome.exitCode ~= 0, "strict mode must not exit zero when the ROM-gated layers were skipped")
  Assert.notNil(outcome.failure, "strict mode needs an actionable message")
  contains(outcome.failure, "rom_dump", "strict failure names the missing capability")
  contains(outcome.failure, "scripts/buildcache.sh", "strict failure names the remediation command")
end

-- Explicitly selecting a ROM-gated layer without a dump is an
-- infrastructure failure, not a green run of skips.
function T.selected_rom_gated_layer_without_a_dump_fails()
  for _, layer in ipairs({ "rom", "acceptance" }) do
    local plan = parse({ "--layer", layer })
    local outcome = Cli.outcome(plan, NO_DUMP, runOf({ [layer] = { skipped = 23 } }))

    Assert.isTrue(outcome.exitCode ~= 0, "--layer " .. layer .. " without a dump must be nonzero")
    Assert.notNil(outcome.failure, "--layer " .. layer .. " without a dump needs an actionable message")
    Assert.isNil(outcome.warning, "a required capability reports a failure, not an optional-skip warning")
  end
end

-- Strict graphics mode is environment-driven, mirrors the ROM strictness, and
-- makes the graphics capability mandatory for a selection that includes the
-- graphics layer.
function T.graphics_strict_mode_comes_from_the_environment()
  local strict = parse({}, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  Assert.isTrue(strict.graphicsStrict, "strict graphics mode must be recorded in the plan")
  Assert.isTrue(hasCapability(strict, "graphics"), "strict graphics mode must require the graphics capability")

  local relaxed = parse({}, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "0" } })
  Assert.isFalse(relaxed.graphicsStrict)
  Assert.isFalse(parse({}, { env = {} }).graphicsStrict)
end

-- Strict graphics mode turns an absent graphics capability into an actionable
-- failure instead of a green run of skips.
function T.graphics_strict_mode_without_the_capability_fails()
  local plan = parse({}, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 }, graphics = { skipped = 45 } })

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.isTrue(outcome.exitCode ~= 0, "strict graphics mode must not exit zero when the graphics layer was skipped")
  Assert.notNil(outcome.failure, "strict graphics mode needs an actionable message")
  contains(outcome.failure, "graphics", "strict graphics failure names the missing capability")
end

-- The execution counter: with the capability available, a whole-run selection
-- that produced no executed graphics test (every graphics test skipped) is a
-- failure under strict mode -- a regression that silently drops the renderer
-- suites must not keep CI green.
function T.graphics_strict_mode_fails_when_every_graphics_test_skipped()
  local plan = parse({}, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 }, graphics = { skipped = 45 } })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.isTrue(outcome.exitCode ~= 0, "strict graphics mode must not exit zero when every graphics test skipped")
  Assert.notNil(outcome.failure, "strict graphics mode needs an actionable message")
  contains(outcome.failure, "no graphics test was executed", "strict failure names the missing execution")
end

-- The same counter when the graphics layer produced no results at all -- the
-- layer exists in the selection but discovered or selected nothing.
function T.graphics_strict_mode_fails_when_the_graphics_layer_executed_nothing()
  local plan = parse({}, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 } })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.isTrue(
    outcome.exitCode ~= 0,
    "a selection with no graphics results at all must fail under strict graphics mode"
  )
  Assert.notNil(outcome.failure)
  contains(outcome.failure, "no graphics test was executed", "strict failure names the missing execution")
end

-- Executed graphics tests satisfy the strict requirement whatever else runs.
function T.graphics_strict_run_with_executed_graphics_tests_stays_green()
  local plan = parse({}, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 }, graphics = { passed = 45 } })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.equal(outcome.exitCode, 0, "executed graphics tests satisfy the strict requirement")
  Assert.isNil(outcome.failure)
end

-- Strict graphics mode is scoped to selections that include the graphics layer:
-- a `--layer unit` partial run and `--list` never trip it.
function T.graphics_strictness_does_not_trip_partial_runs_or_listing()
  local unitPlan = parse({ "--layer", "unit" }, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  Assert.isFalse(hasCapability(unitPlan, "graphics"), "a unit-only selection must not require the graphics capability")

  local unitOutcome = Cli.outcome(unitPlan, NO_DUMP, runOf({ unit = { passed = 1194 } }))
  Assert.equal(unitOutcome.exitCode, 0, "a unit-only partial run must stay green under strict graphics mode")
  Assert.isNil(unitOutcome.failure)

  local listing = parse({ "--list" }, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  Assert.isTrue(listing.list, "--list still parses under strict graphics mode")
end

-- An explicit filter is a narrowing the user asked for: it never triggers the
-- execution counter (the generic empty-run failure still guards a filter that
-- matches nothing at all).
function T.graphics_strict_mode_respects_an_explicit_filter()
  local plan = parse({ "--filter", "warp" }, { env = { G4RECOMP_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 } })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.equal(outcome.exitCode, 0, "a filter that narrows away from the graphics layer is an explicit selection")
  Assert.isNil(outcome.failure)
end

-- The exit status is combined across layers -- a failure anywhere is a
-- failure of the run.
function T.exit_status_combines_failures_from_every_layer()
  for _, layer in ipairs({ "unit", "component", "graphics", "rom", "acceptance" }) do
    local run = runOf({ unit = { passed = 1194 }, [layer] = { passed = 3, failed = 1 } })
    local outcome = Cli.outcome(parse({}), READY_DUMP, run)
    Assert.equal(outcome.exitCode, 1, "a failure in the " .. layer .. " layer must exit nonzero")
  end
end

-- A run that executed nothing is never reported as success -- this is
-- what a filter that matches no test looks like.
function T.a_run_that_executed_nothing_is_not_success()
  local plan = parse({ "--filter", "no-such-test" })

  local outcome = Cli.outcome(plan, READY_DUMP, runOf({}))

  Assert.isTrue(outcome.exitCode ~= 0, "zero executed tests must not read as a green run")
  Assert.notNil(outcome.failure)
  contains(outcome.failure, "no-such-test", "the empty-selection failure names the filter")
end

-- The report names the ready game versions the run exercised.
function T.report_names_the_ready_versions_exercised()
  local run = runOf({ unit = { passed = 1 } }, { versions = { "heartgold", "soulsilver" } })

  local text = table.concat(Report.lines(run), "\n")

  contains(text, "heartgold", "report names the ready versions exercised")
  contains(text, "soulsilver", "report names the ready versions exercised")
end

return { tests = T }
