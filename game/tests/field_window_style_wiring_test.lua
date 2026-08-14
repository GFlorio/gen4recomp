-- FieldRuntime window-style composition contract: the production runtime
-- constructs the FieldWindowStyleRegistry from the generated field-UI
-- manifest it already loads, seals it before the script platform exists,
-- and exposes it as `runtime.windowStyles`. Style definitions are boot
-- configuration, never persisted state.

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
    Assert.equal(dialogue.assets.frame, "hgss.dialogue_frame.tiles")
    local signpost = assert(registry:resolve("hgss.signpost"))
    Assert.equal(signpost.assets.frame, "hgss.signpost.tiles")
    Assert.equal(signpost.assets.mapGraphic, "hgss.signpost.wayfinding")
    Assert.isTrue(type(signpost.types[0]) == "table", "the real manifest type map must flow through")
    Assert.isTrue(signpost.types[0].graphicRegion ~= nil, "type 0 keeps its wayfinding region")
    Assert.equal(assert(registry:resolve("hgss.trainer_tip")).role, "trainer_tip")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
