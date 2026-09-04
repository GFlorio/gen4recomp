-- App command-line option parsing (the argv love.load hands to app/main.lua).
-- The parser is deliberately small: exactly the documented project options
-- parse; any unknown option or stray argument is rejected; and a --test
-- invocation defers the whole argv to the test command,
-- whose own parser (tests/runner/Cli.lua) rejects everything it does not know
-- with the usage exit status.

local Assert = require("tests.support.Assert")
local Options

local T = {}

---@param text string
---@param needle string
---@return boolean
local function contains(text, needle)
  return text:find(needle, 1, true) ~= nil
end

local function loadOptions()
  if Options ~= nil then
    return Options
  end
  local ok, optionsOrError = pcall(require, "app.src.Options")
  Assert.isTrue(ok, "the app shell must provide app.src.Options: " .. tostring(optionsOrError))
  Options = optionsOrError
  return Options
end

-- parse() must reject and carry a message naming the offending input.
local function rejects(argv)
  local opts, message = loadOptions().parse(argv)
  Assert.isNil(opts, "must reject: " .. table.concat(argv, " "))
  Assert.notNil(message, "rejection carries a message")
  return assert(message)
end

-- Raises when parsing unexpectedly failed so a contract test fails on the
-- parser defect rather than on a nil index further down.
---@param argv string[]
---@return LaunchOptions
local function parses(argv)
  local opts, message = loadOptions().parse(argv)
  Assert.isTrue(opts ~= nil, "expected opts for " .. table.concat(argv, " ") .. ", got error: " .. tostring(message))
  ---@cast opts LaunchOptions
  return opts
end

function T.no_options_default_to_the_normal_boot_flow()
  local opts = parses({})
  Assert.isFalse(opts.test)
  Assert.isFalse(opts.dev)
  Assert.keySet(opts, "dev,test")
end

function T.remaining_product_options_parse()
  Assert.isTrue(parses({ "--dev" }).dev)
end

function T.usage_advertises_the_app_root()
  local usage = loadOptions().USAGE
  Assert.isTrue(usage:find("love app/", 1, true) ~= nil, "usage must name the app root")
  Assert.isFalse(usage:find("--actors", 1, true) ~= nil, "usage must not advertise the removed launch mode")
end

function T.dev_modifier_composes_with_the_normal_boot_mode()
  Assert.isTrue(parses({ "--dev" }).dev)
end

function T.removed_actor_launch_flag_is_rejected_as_an_unknown_option()
  local message = rejects({ "--actors" })
  Assert.isTrue(contains(message, "unknown option '--actors'"))
end

function T.unknown_options_are_rejected()
  Assert.isTrue(contains(rejects({ "--bogus" }), "--bogus"))
  Assert.isTrue(contains(rejects({ "--test=1" }), "--test=1"))
  Assert.isTrue(contains(rejects({ "--bogus", "--dev" }), "--bogus"))
end

function T.stray_arguments_are_rejected()
  Assert.isTrue(contains(rejects({ "foo" }), "foo"))
  Assert.isTrue(contains(rejects({ "-x" }), "-x"))
end

function T.stray_arguments_after_modes_are_rejected()
  Assert.isTrue(contains(rejects({ "--dev", "foo" }), "foo"))
end

-- The test command owns argument parsing once --test is present: the app
-- parser defers the whole argv (the runner accepts --test itself and rejects
-- every unknown option with the usage status).
function T.test_mode_defers_every_remaining_argument_to_the_test_command()
  local opts = parses({ "--test", "--list", "--layer", "unit" })
  Assert.isTrue(opts.test)

  local mixed = parses({ "--test", "--dev", "--bogus" })
  Assert.isTrue(mixed.test)
end

return { tests = T }
