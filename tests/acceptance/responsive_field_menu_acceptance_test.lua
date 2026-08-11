-- Production-composed responsive field-menu contract. A generated HGSS menu
-- must retain its script result while FieldRuntime selects a surface and
-- presentation suited to the active display topology; drawing stays trapped.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "menu", "responsive", "topology", "script" },
  },
  tests = {},
}

local VANILLA_MENU = "vanilla.hgss.scr_seq.0003.script_056"
local RESULT_VARIABLE = 32780

local CONFIGURATIONS = {
  {
    id = "four_by_three",
    fieldOptions = { viewportWidth = 1280, viewportHeight = 960 },
    surface = "main",
    presentation = "floating",
  },
  {
    id = "wide",
    fieldOptions = { viewportWidth = 1920, viewportHeight = 1080 },
    surface = "main",
    presentation = "floating",
  },
  {
    id = "portrait",
    fieldOptions = { viewportWidth = 390, viewportHeight = 844 },
    surface = "main",
    presentation = "docked",
  },
  {
    id = "dual_surface",
    fieldOptions = {
      viewportWidth = 1280,
      viewportHeight = 720,
      screenTopology = ScreenTopology.dualDisplay(
        { id = "main", rect = { x = 0, y = 0, width = 960, height = 720 }, touch = false, role = "world" },
        { id = "auxiliary", rect = { x = 960, y = 0, width = 320, height = 720 }, touch = true, role = "auxiliary" }
      ),
    },
    surface = "auxiliary",
    presentation = "docked",
  },
}

local function contains(outer, inner)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

local function withGame(configuration, fn)
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    save = "fresh",
    fieldOptions = configuration.fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function openMenu(game)
  game:startScript(VANILLA_MENU)
  return game:advanceUntil("vanilla menu becomes modal", function(snapshot)
    return snapshot.menu ~= nil and snapshot.menu.modal == true
  end, 120)
end

local function selectSecondItem(game)
  game.runtime.input:pressUi("down", "key:s")
  game:step()
  game.runtime.input:releaseUi("down", "key:s")
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
  game:advanceUntil("menu closes after semantic selection", function(snapshot)
    return snapshot.menu ~= nil and not snapshot.menu.modal
  end, 120)
end

-- FM-14-01: a real 749--752 menu crosses FieldRuntime's topology composition
-- before its script result is committed. The same second choice must remain
-- value 1 on every form factor; its surface and presentation are observable
-- production state, not a unit-level layout reconstruction.
function T.tests.vanilla_menu_is_responsive_without_changing_its_script_result()
  for _, configuration in ipairs(CONFIGURATIONS) do
    withGame(configuration, function(game)
      local opened = openMenu(game)
      local layout = assert(opened.menu.layout, "modal menu must expose production layout")
      Assert.equal(layout.surface.id, configuration.surface, configuration.id .. " selected surface")
      Assert.equal(layout.presentation, configuration.presentation, configuration.id .. " presentation")
      Assert.isTrue(contains(layout.surface.safeRect, layout.frame), configuration.id .. " frame is safe")

      selectSecondItem(game)
      Assert.equal(
        game.runtime.scripts.worldState:getVar(RESULT_VARIABLE),
        1,
        configuration.id .. " preserves the vanilla script-defined value"
      )
    end)
  end
end

return T
