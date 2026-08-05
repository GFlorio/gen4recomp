local Assert = require("tests.support.Assert")
local Cli = require("romdump.src.cli.Cli")

local T = {}

function T.defaults_are_all_off()
  local o = Cli.parse({})
  Assert.isFalse(o.test)
  Assert.isNil(o.importRom)
  Assert.isFalse(o.importOnly)
  Assert.isFalse(o.checkDump)
  Assert.isFalse(o.testPrivate)
end

function T.parses_flags()
  local o = Cli.parse({ "--import-rom", "/tmp/hg.nds", "--import-only", "--check-dump", "--test" })
  Assert.equal(o.importRom, "/tmp/hg.nds")
  Assert.isTrue(o.importOnly)
  Assert.isTrue(o.checkDump)
  Assert.isTrue(o.test)
end

function T.parses_test_private()
  Assert.isTrue(Cli.parse({ "--test-private" }).testPrivate)
end

function T.ignores_unknown_tokens()
  local o = Cli.parse({ "--fused", "--console", "--import-only" })
  Assert.isTrue(o.importOnly)
end

function T.missing_value_for_import_rom_errors()
  Assert.throws(function() Cli.parse({ "--import-rom" }) end)
end

function T.parses_inspect()
  Assert.isTrue(Cli.parse({ "--inspect" }).inspect)
  Assert.isFalse(Cli.parse({}).inspect)
end

function T.parses_build()
  Assert.isTrue(Cli.parse({ "--build" }).build)
  Assert.isFalse(Cli.parse({}).build)
end

return T
