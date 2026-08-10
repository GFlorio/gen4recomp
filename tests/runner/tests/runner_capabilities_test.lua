-- Capability detection for a test run. A ready raw dump is only
-- `rom_dump`; the derived cache is a separate capability the shell entrypoint
-- establishes by running the incremental builder before the suite, so an
-- unprepared dump can never claim `derived_cache`.

local Assert = require("tests.support.Assert")
local Capabilities = require("tests.runner.Capabilities")

local T = {}

local function detect(ready, env)
  return Capabilities.detect({
    versions = { "heartgold", "soulsilver" },
    isReady = function(versionId)
      return ready[versionId] == true
    end,
    env = env or {},
  })
end

function T.no_ready_dump_offers_no_rom_capabilities()
  local capabilities, versions = detect({}, { [Capabilities.DERIVED_CACHE_ENV] = "1" })

  Assert.isNil(capabilities.rom_dump)
  Assert.isNil(capabilities.derived_cache)
  Assert.deepEqual(versions, {})
end

function T.a_ready_dump_without_preparation_is_not_a_derived_cache()
  local capabilities, versions = detect({ heartgold = true })

  Assert.isTrue(capabilities.rom_dump)
  Assert.isNil(capabilities.derived_cache, "an unprepared cache must not claim derived_cache")
  Assert.deepEqual(versions, { "heartgold" })
end

function T.a_prepared_ready_dump_offers_both_capabilities_and_names_versions()
  local capabilities, versions = detect(
    { heartgold = true, soulsilver = true },
    { [Capabilities.DERIVED_CACHE_ENV] = "1" }
  )

  Assert.isTrue(capabilities.rom_dump)
  Assert.isTrue(capabilities.derived_cache)
  Assert.deepEqual(versions, { "heartgold", "soulsilver" }, "versions follow the declared order")
end

return T
