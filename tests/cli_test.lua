local Assert = require("tests.support.Assert")
local Cli = require("src.app.Cli")

local T = {}

-- A getenv that returns nil for everything, unless overridden per-test.
local function env(map)
  return function(name) return map and map[name] or nil end
end

function T.defaults_are_all_off()
  local o = Cli.parse({}, env())
  Assert.isFalse(o.test)
  Assert.isNil(o.importRom)
  Assert.isFalse(o.importOnly)
  Assert.isNil(o.version)
  Assert.isFalse(o.diagnostic)
  Assert.isFalse(o.checkDump)
end

function T.parses_value_and_bool_flags()
  local o = Cli.parse(
    { "--import-rom", "/tmp/hg.nds", "--version", "heartgold", "--import-only", "--check-dump" },
    env())
  Assert.equal(o.importRom, "/tmp/hg.nds")
  Assert.equal(o.version, "heartgold")
  Assert.isTrue(o.importOnly)
  Assert.isTrue(o.checkDump)
end

function T.env_fills_unset_options()
  local o = Cli.parse({}, env({
    G4RECOMP_IMPORT_ROM = "/env/rom.nds",
    G4RECOMP_VERSION = "soulsilver",
    G4RECOMP_IMPORT_ONLY = "1",
    G4RECOMP_CHECK_DUMP = "1",
  }))
  Assert.equal(o.importRom, "/env/rom.nds")
  Assert.equal(o.version, "soulsilver")
  Assert.isTrue(o.importOnly)
  Assert.isTrue(o.checkDump)
end

function T.flag_wins_over_env()
  local o = Cli.parse({ "--import-rom", "/flag/rom.nds" },
    env({ G4RECOMP_IMPORT_ROM = "/env/rom.nds" }))
  Assert.equal(o.importRom, "/flag/rom.nds")
end

function T.empty_env_is_ignored()
  local o = Cli.parse({}, env({ G4RECOMP_IMPORT_ONLY = "", G4RECOMP_CHECK_DUMP = "0" }))
  Assert.isFalse(o.importOnly)
  Assert.isFalse(o.checkDump)
end

function T.rejects_unknown_version()
  Assert.throws(function() Cli.parse({ "--version", "crystal" }, env()) end)
  Assert.throws(function() Cli.parse({}, env({ G4RECOMP_VERSION = "crystal" })) end)
end

function T.missing_value_for_import_rom_errors()
  Assert.throws(function() Cli.parse({ "--import-rom" }, env()) end)
end

return T
