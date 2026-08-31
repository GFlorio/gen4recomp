-- FieldRuntime window-style composition contract: the production runtime
-- constructs the immutable FieldWindowStyles catalogue from the generated
-- field-UI manifest it already loads and exposes it as `runtime.windowStyles`.
-- The catalogue holds the production-owned built-in styles only: no boot
-- configuration can add or replace entries, so unknown ids never resolve.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "presentation", "catalog" },
  },
  tests = {},
}

function T.tests.runtime_composes_the_window_style_catalogue()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local styles = game.runtime.windowStyles
    Assert.isTrue(type(styles) == "table", "the runtime must expose the window style catalogue")

    local signpost = assert(styles:resolve("hgss.signpost"))
    Assert.isNil(signpost.assets, "styles carry no asset-replacement ids")
    Assert.isTrue(type(signpost.types[0]) == "table", "the real manifest type map must flow through")
    Assert.isTrue(signpost.types[0].graphicRegion ~= nil, "type 0 keeps its wayfinding region")
    Assert.notNil(styles:resolve("hgss.trainer_tip"), "the trainer-tip style must resolve")
    Assert.isNil(
      styles:resolve("mod.route_sign"),
      "the production catalogue holds built-ins only: no external style can resolve"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
