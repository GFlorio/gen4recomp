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
  Assert.isFalse(o.buildCache)
  Assert.isFalse(o.forceDump)
  Assert.isFalse(o.allowCompileExclusions)
  Assert.isFalse(o.inspectActors)
end

function T.parses_inspect_actors()
  local o = Cli.parse({ "--inspect-actors" })
  Assert.isTrue(o.inspectActors)
  Assert.isFalse(o.inspect)
end

function T.parses_allow_compile_exclusions()
  local o = Cli.parse({ "--build-cache", "--allow-compile-exclusions" })
  Assert.isTrue(o.buildCache)
  Assert.isTrue(o.allowCompileExclusions)
  Assert.isNil(o.importRom)
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

function T.parses_analyze_maps()
  Assert.isTrue(Cli.parse({ "--analyze-maps" }).analyzeMaps)
  Assert.isFalse(Cli.parse({}).analyzeMaps)
end

function T.parses_build_cache_with_optional_rom()
  local withoutRom = Cli.parse({ "--build-cache" })
  Assert.isTrue(withoutRom.buildCache)
  Assert.isNil(withoutRom.importRom)

  local withRom = Cli.parse({ "--build-cache", "/tmp/hg.nds" })
  Assert.isTrue(withRom.buildCache)
  Assert.equal(withRom.importRom, "/tmp/hg.nds")
end

function T.parses_forcedump_with_required_rom()
  local o = Cli.parse({ "--build-cache", "--forcedump", "/tmp/hg.nds" })
  Assert.isTrue(o.buildCache)
  Assert.isTrue(o.forceDump)
  Assert.equal(o.importRom, "/tmp/hg.nds")
end

function T.forcedump_requires_rom()
  Assert.throws(function() Cli.parse({ "--build-cache", "--forcedump" }) end)
  Assert.throws(function() Cli.parse({ "--forcedump", "--build-cache" }) end)
end

return T
