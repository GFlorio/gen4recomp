-- Production-composed bindings-manifest contract. The production load path
-- (FieldRuntime -> FieldScripts -> Bindings.new) must reject a manifest that
-- carries a trigger kind no dispatcher resolves: coordinate/map_init/
-- map_enter/map_resume bindings can never fire, so carrying one is a schema
-- error, not data the loader silently accepts. The scenario feeds the real
-- production manifest a coordinate binding and pins the boot to fail with
-- the bindings manifest schema error instead of booting with dead bindings.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "bindings", "boot" },
  },
  tests = {},
}

-- The exact code Bindings.new must raise for a malformed manifest: the
-- scenario pins the code so the rejection is named, not any boot failure.
local BINDINGS_MANIFEST_INVALID = "SCRIPT_BINDING_MANIFEST_INVALID"

-- Booting with a manifest that carries an undispatched trigger kind must
-- fail at load with the bindings manifest schema error. The manifest module
-- is shared process state (FieldRuntime requires it once), so the scenario
-- injects a coordinate binding into map 60, boots, and restores the original
-- entry on every path before asserting.
function T.tests.manifest_with_an_undispatched_trigger_kind_is_rejected_at_boot()
  local manifest = require("data.scripts.manifests.vanilla_bindings")
  local map60 = assert(manifest.maps[60], "production bindings manifest must cover New Bark Town")
  local savedCoordinates = map60.coordinates
  map60.coordinates = { [0] = "vanilla.hgss.scr_seq.0842.script_002" }

  local game
  local ok, err = pcall(function()
    game = AcceptanceHarness.new():boot({
      versionId = "heartgold",
      map = "MAP_NEW_BARK",
      save = "fresh",
    })
  end)
  map60.coordinates = savedCoordinates
  if game then
    game:close()
  end

  Assert.isFalse(ok, "a manifest carrying an undispatched trigger kind must fail the boot")
  Assert.isTrue(
    tostring(err):find("acceptance runtime boot failed: " .. BINDINGS_MANIFEST_INVALID, 1, true) ~= nil,
    "boot must fail with the bindings manifest schema error, got: " .. tostring(err)
  )
end

return T
