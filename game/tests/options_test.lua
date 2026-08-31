-- Game command-line option parsing (the argv love.load hands to game/main.lua).
-- The parser is deliberately small: exactly the documented project options
-- parse; any unknown option or stray argument is rejected; and a --test
-- invocation defers the whole argv to the test command,
-- whose own parser (tests/runner/Cli.lua) rejects everything it does not know
-- with the usage exit status.

local Assert = require("tests.support.Assert")
local Options = require("game.src.Options")

local T = {}

---@param text string
---@param needle string
---@return boolean
local function contains(text, needle)
  return text:find(needle, 1, true) ~= nil
end

-- parse() must reject and carry a message naming the offending input.
local function rejects(argv)
  local opts, message = Options.parse(argv)
  Assert.isNil(opts, "must reject: " .. table.concat(argv, " "))
  Assert.notNil(message, "rejection carries a message")
  return assert(message)
end

-- Raises when parsing unexpectedly failed so a contract test fails on the
-- parser defect rather than on a nil index further down.
---@param argv string[]
---@return LaunchOptions
local function parses(argv)
  local opts, message = Options.parse(argv)
  Assert.isTrue(opts ~= nil, "expected opts for " .. table.concat(argv, " ") .. ", got error: " .. tostring(message))
  ---@cast opts LaunchOptions
  return opts
end

function T.no_options_default_to_the_normal_boot_flow()
  local opts = parses({})
  Assert.isFalse(opts.test)
  Assert.isFalse(opts.actors)
  Assert.isFalse(opts.dev)
end

function T.remaining_product_options_parse()
  Assert.isTrue(parses({ "--actors" }).actors)
  Assert.isTrue(parses({ "--dev" }).dev)
end

function T.modifiers_compose_with_the_modes_they_apply_to()
  local preview = parses({ "--actors", "--dev" })
  Assert.isTrue(preview.actors)
  Assert.isTrue(preview.dev)
end

function T.removed_field_mode_is_rejected_before_app_boot()
  for _, argv in ipairs({ { "--field" }, { "--field", "MAP_NEW_BARK" } }) do
    local message = assert(rejects(argv))
    Assert.isTrue(message:find("unknown option", 1, true) ~= nil, "removed mode uses the option error path")
    local usage = assert(message:match("\n(usage:.*)$"))
    Assert.isTrue(usage:find("--field", 1, true) == nil, "usage does not advertise the removed mode")
  end
end

function T.unknown_options_are_rejected()
  contains(rejects({ "--bogus" }), "--bogus")
  contains(rejects({ "--field=elms_lab" }), "--field=elms_lab")
  contains(rejects({ "--test=1" }), "--test=1")
  contains(rejects({ "--bogus", "--dev" }), "--bogus")
end

function T.stray_arguments_are_rejected()
  contains(rejects({ "foo" }), "foo")
  contains(rejects({ "-x" }), "-x")
end

function T.stray_arguments_after_modes_are_rejected()
  contains(rejects({ "--actors", "foo" }), "foo")
end

-- The test command owns argument parsing once --test is present: the game
-- parser defers the whole argv (the runner accepts --test itself and rejects
-- every unknown option with the usage status).
function T.test_mode_defers_every_remaining_argument_to_the_test_command()
  local opts = parses({ "--test", "--list", "--layer", "unit" })
  Assert.isTrue(opts.test)

  local mixed = parses({ "--test", "--actors", "--dev", "--bogus" })
  Assert.isTrue(mixed.test)
end

return { tests = T }
