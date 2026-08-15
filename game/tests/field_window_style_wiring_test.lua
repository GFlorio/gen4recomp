-- FieldRuntime window-style composition contract: the production runtime
-- constructs the FieldWindowStyleRegistry from the generated field-UI
-- manifest it already loads, seals it before the script platform exists,
-- and exposes it as `runtime.windowStyles`. Style definitions are boot
-- configuration, never persisted state. Boot-config mod descriptors
-- register after the built-ins and before the seal (the pre-seal
-- registration seam the high-level sign operations resolve against).

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "presentation", "registry" },
  },
  tests = {},
}

function T.tests.runtime_composes_and_seals_the_window_style_registry()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local registry = game.runtime.windowStyles
    Assert.isTrue(type(registry) == "table", "the runtime must expose the window style registry")
    Assert.equal(registry.sealed, true, "the runtime registry must be sealed before scripts run")

    local dialogue = assert(registry:resolve("hgss.dialogue"))
    Assert.equal(dialogue.role, "dialogue")
    Assert.isNil(dialogue.assets, "styles carry no asset-replacement ids")
    local signpost = assert(registry:resolve("hgss.signpost"))
    Assert.isNil(signpost.assets)
    Assert.isTrue(type(signpost.types[0]) == "table", "the real manifest type map must flow through")
    Assert.isTrue(signpost.types[0].graphicRegion ~= nil, "type 0 keeps its wayfinding region")
    Assert.equal(assert(registry:resolve("hgss.trainer_tip")).role, "trainer_tip")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- A boot-config mod style descriptor registers after the built-ins and
-- before the seal: the resolved record inherits the base's geometry and
-- role and carries the mod's own identity.
function T.tests.boot_config_mod_style_descriptors_register_before_the_seal()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      windowStyleDescriptors = {
        {
          id = "mod.route_sign",
          base = "hgss.signpost",
        },
      },
    },
  })
  local ok, err = xpcall(function()
    local registry = game.runtime.windowStyles
    Assert.equal(registry.sealed, true)
    local mod = assert(registry:resolve("mod.route_sign"), "the mod style must resolve through the sealed registry")
    Assert.equal(mod.role, "signpost", "the mod style inherits the base role")
    Assert.equal(mod.id, "mod.route_sign", "the mod style reports its own id")
    Assert.isNil(mod.assets, "the mod style inherits no asset-replacement ids")
    Assert.deepEqual(mod.contentGeometry, { x = 16, y = 152, width = 216, height = 32 })
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
