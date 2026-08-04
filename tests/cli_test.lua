local Assert = require("tests.support.Assert")
local Cli = require("src.app.Cli")

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

function T.parses_inspect_map()
  Assert.equal(Cli.parse({ "--inspect-map", "MAP_NEW_BARK" }).inspectMap, "MAP_NEW_BARK")
  Assert.isNil(Cli.parse({}).inspectMap)
end

function T.missing_value_for_inspect_map_errors()
  Assert.throws(function() Cli.parse({ "--inspect-map" }) end)
end

function T.parses_build_map()
  Assert.equal(Cli.parse({ "--build-map", "MAP_NEW_BARK_ELMS_LAB_1F" }).buildMap, "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.isNil(Cli.parse({}).buildMap)
end

function T.missing_value_for_build_map_errors()
  Assert.throws(function() Cli.parse({ "--build-map" }) end)
end

function T.parses_map()
  Assert.equal(Cli.parse({ "--map", "MAP_NEW_BARK_ELMS_LAB_1F" }).map, "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.isNil(Cli.parse({}).map)
end

function T.missing_value_for_map_errors()
  Assert.throws(function() Cli.parse({ "--map" }) end)
end

return T
