-- FieldRuntime window-style composition contract: the production runtime
-- constructs the immutable FieldWindowStyles catalogue from the generated
-- field-UI manifest it already loads and exposes it as `runtime.windowStyles`.
-- Style definitions are boot configuration, never persisted state; boot-config
-- mod descriptors are complete records merged into the catalogue at
-- construction.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "presentation", "registry" },
  },
  tests = {},
}

function T.tests.runtime_composes_the_window_style_catalogue()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local styles = game.runtime.windowStyles
    Assert.isTrue(type(styles) == "table", "the runtime must expose the window style catalogue")

    local dialogue = assert(styles:resolve("hgss.dialogue"))
    Assert.equal(dialogue.role, "dialogue")
    Assert.isNil(dialogue.assets, "styles carry no asset-replacement ids")
    local signpost = assert(styles:resolve("hgss.signpost"))
    Assert.isNil(signpost.assets)
    Assert.isTrue(type(signpost.types[0]) == "table", "the real manifest type map must flow through")
    Assert.isTrue(signpost.types[0].graphicRegion ~= nil, "type 0 keeps its wayfinding region")
    Assert.equal(assert(styles:resolve("hgss.trainer_tip")).role, "trainer_tip")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- A boot-config complete custom descriptor resolves through the runtime
-- catalogue alongside the built-ins.
function T.tests.boot_config_custom_style_resolves_through_the_runtime_catalogue()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      windowStyleDescriptors = {
        {
          id = "mod.route_sign",
          role = "signpost",
          contentGeometry = { x = 16, y = 152, width = 216, height = 32 },
        },
      },
    },
  })
  local ok, err = xpcall(function()
    local styles = game.runtime.windowStyles
    local mod = assert(styles:resolve("mod.route_sign"), "the mod style must resolve through the runtime catalogue")
    Assert.equal(mod.role, "signpost")
    Assert.equal(mod.id, "mod.route_sign", "the mod style reports its own id")
    Assert.isNil(mod.assets, "the mod style carries no asset-replacement ids")
    Assert.deepEqual(mod.contentGeometry, { x = 16, y = 152, width = 216, height = 32 })
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
