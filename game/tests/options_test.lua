-- Game command-line option parsing (the argv love.load hands to game/main.lua).
-- The parser is deliberately small: exactly the documented project options
-- parse; any unknown option, stray argument, or conflicting execution mode is
-- rejected; and a --test invocation defers the whole argv to the test command,
-- whose own parser (tests/runner/Cli.lua) rejects everything it does not know
-- with the usage exit status.

local Assert = require("tests.support.Assert")
local Options = require("game.src.Options")

local T = {}

local function contains(text, needle)
  return text:find(needle, 1, true) ~= nil
end

-- parse() must reject and carry a message naming the offending input.
local function rejects(argv)
  local opts, message = Options.parse(argv)
  Assert.isNil(opts, "must reject: " .. table.concat(argv, " "))
  Assert.notNil(message, "rejection carries a message")
  return message
end

-- Raises when parsing unexpectedly failed so a contract test fails on the
-- parser defect rather than on a nil index further down.
---@return GameOptions opts
local function parses(argv)
  local opts, message = Options.parse(argv)
  Assert.isTrue(opts ~= nil, "expected opts for " .. table.concat(argv, " ") .. ", got error: " .. tostring(message))
  return opts --[[@as GameOptions]]
end

function T.no_options_default_to_the_normal_boot_flow()
  local opts = parses({})
  Assert.isFalse(opts.test)
  Assert.isNil(opts.field)
  Assert.isFalse(opts.actors)
  Assert.isFalse(opts.dev)
  Assert.isFalse(opts.newFieldSession)
end

function T.documented_options_parse()
  local bare = parses({ "--field" })
  Assert.equal(bare.field, true)
  Assert.isFalse(bare.actors)

  local symbolic = parses({ "--field", "elms_lab" })
  Assert.equal(symbolic.field, "elms_lab")

  local numeric = parses({ "--field", "12" })
  Assert.equal(numeric.field, "12")

  Assert.isTrue(parses({ "--actors" }).actors)
  Assert.isTrue(parses({ "--dev" }).dev)
  Assert.isTrue(parses({ "--new-field-session" }).newFieldSession)
end

-- --field consumes at most one following non-option token.
function T.field_never_consumes_a_following_option()
  local opts = parses({ "--field", "--dev" })
  Assert.equal(opts.field, true)
  Assert.isTrue(opts.dev)
end

function T.modifiers_compose_with_the_modes_they_apply_to()
  local fieldBoot = parses({ "--field", "--dev", "--new-field-session" })
  Assert.equal(fieldBoot.field, true)
  Assert.isTrue(fieldBoot.dev)
  Assert.isTrue(fieldBoot.newFieldSession)

  local preview = parses({ "--actors", "--dev" })
  Assert.isTrue(preview.actors)
  Assert.isTrue(preview.dev)
end

function T.unknown_options_are_rejected()
  contains(rejects({ "--bogus" }), "--bogus")
  contains(rejects({ "--field=elms_lab" }), "--field=elms_lab")
  contains(rejects({ "--test=1" }), "--test=1")
  contains(rejects({ "--field", "--bogus" }), "--bogus")
end

function T.stray_arguments_are_rejected()
  contains(rejects({ "foo" }), "foo")
  contains(rejects({ "-x" }), "-x")
end

function T.conflicting_execution_modes_are_rejected()
  contains(rejects({ "--actors", "--field" }), "--actors")
  contains(rejects({ "--field", "--actors" }), "--actors")
  contains(rejects({ "--actors", "--field", "elms_lab" }), "--actors")
end

-- The test command owns argument parsing once --test is present: the game
-- parser defers the whole argv (the runner accepts --test itself and rejects
-- every unknown option with the usage status).
function T.test_mode_defers_every_remaining_argument_to_the_test_command()
  local opts = parses({ "--test", "--list", "--layer", "unit" })
  Assert.isTrue(opts.test)

  local conflict = parses({ "--field", "--test" })
  Assert.isTrue(conflict.test)

  local mixed = parses({ "--test", "--actors", "--dev", "--bogus" })
  Assert.isTrue(mixed.test)
end

return { tests = T }
