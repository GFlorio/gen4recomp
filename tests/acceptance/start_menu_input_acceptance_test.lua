-- Production-composed Start Menu input contract: the runtime must map the
-- required `menu` binding from data/manifests/field_presentation.lua through
-- the same binding construction as Action/Cancel (keyboard "x" stays Cancel),
-- and the production-composed FieldInput must carry the semantic menu button
-- with the Action/Cancel ownership model: one press edge per zero-to-one
-- source transition, consumed exactly once by a snapshot, cleared by edge
-- clears without dropping held state, and fully cleared by focus loss so a
-- stray release cannot resurrect it. The second boot replaces the manifest's
-- menu binding with another key and pins that the runtime reads the manifest
-- rather than hard-coding the key. Nothing here opens the menu or renders.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "input", "start-menu", "bindings" },
  },
  tests = {},
}

-- The required menu binding: keyboard "m"; keyboard "x" remains the existing
-- Cancel binding. The gamepad west face button mapping is FieldState
-- (graphics-layer) composition and stays out of this non-rendering flow.
local MENU_KEY = "m"
local OTHER_MENU_KEY = "n"

function T.tests.production_input_pipeline_carries_the_semantic_menu_button_and_its_required_binding()
  local harness = AcceptanceHarness.new()
  local game =
    harness:boot({ versionId = AcceptanceHarness.defaultVersion(), map = "MAP_BURNED_TOWER_1F", save = "fresh" })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    ---@diagnostic disable-next-line: undefined-field -- the runtime menu-bindings surface is the contract under test
    local menuKeys = runtime.menuKeys
    Assert.isTrue(
      type(menuKeys) == "table",
      "the production runtime must expose the required menu binding through the same construction as Action/Cancel, got: "
        .. tostring(menuKeys)
    )
    ---@diagnostic disable-next-line: need-check-nil -- asserted by the preceding isTrue contract
    Assert.equal(menuKeys[MENU_KEY], true, "the required menu binding (keyboard " .. MENU_KEY .. ") must be mapped")
    Assert.equal(runtime.actionKeys["z"], true, "the existing Action binding construction must be unchanged")
    Assert.equal(runtime.cancelKeys["x"], true, "keyboard x must remain the existing Cancel binding")

    -- The semantic menu button on the production-composed input, following
    -- the Action/Cancel ownership model exactly: the menu is a distinct
    -- edge from Action/Cancel because the source's start-menu task closes
    -- on X as well as B (src/start_menu.c:576), and the session routes a
    -- fresh menu edge to the controller while the menu owns the tick.
    local input = runtime.input ---@type any
    Assert.isTrue(
      type(input) == "table" and type(input.pressMenu) == "function",
      "the production input must expose the semantic menu button"
    )

    input:pressMenu("runtime")
    Assert.equal(input.menuDown, true, "a held menu button must read down")
    local first = input:snapshot()
    Assert.equal(first.menuPressed, true, "the zero-to-one menu press must produce one press edge in the snapshot")
    Assert.equal(first.menuDown, true, "held menu state must carry in the snapshot")
    local second = input:snapshot()
    Assert.isNil(second.menuPressed, "the menu press edge must be consumed exactly once by the snapshot")
    Assert.equal(second.menuDown, true, "held menu state must survive edge consumption")

    input:pressMenu("runtime")
    Assert.isNil(input:snapshot().menuPressed, "a repeat press from an already-held source must not produce a new edge")

    input:clearEdges()
    Assert.equal(input.menuDown, true, "edge clears must keep the held menu button down")
    input:releaseMenu("runtime")
    Assert.equal(input.menuDown, false, "releasing the last menu source must lower the button")
    Assert.isNil(input:snapshot().menuPressed, "a release must never produce a menu press edge")

    input:pressMenu("runtime")
    input:clearAll()
    Assert.equal(input.menuDown, false, "focus loss must clear the held menu button")
    input:releaseMenu("runtime")
    Assert.equal(input.menuDown, false, "a stray release after focus loss must not resurrect the menu button")

    Assert.equal(game:renderAttempts(), 0, "the input contract must not render")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end

  -- The binding must be mapped from the manifest by the runtime construction,
  -- not a one-off hard-coded key branch: replacing the manifest's menu binding
  -- with another key must change what the next boot maps.
  local presentation = require("data.manifests.field_presentation")
  local savedMenu = presentation.input.menu
  presentation.input.menu = { OTHER_MENU_KEY }
  local game2
  local bootOk, bootErr = pcall(function()
    game2 =
      harness:boot({ versionId = AcceptanceHarness.defaultVersion(), map = "MAP_BURNED_TOWER_1F", save = "fresh" })
  end)
  presentation.input.menu = savedMenu
  if not bootOk then
    if game2 then
      game2:close()
    end
    error(bootErr, 0)
  end
  local ok2, err2 = xpcall(function()
    local menuKeys = game2.runtime.menuKeys
    Assert.isTrue(
      type(menuKeys) == "table",
      "the mapped menu binding must follow the manifest menu binding, got: " .. tostring(menuKeys)
    )
    Assert.equal(
      menuKeys[OTHER_MENU_KEY],
      true,
      "the mapped menu binding must follow the manifest menu binding, got: " .. tostring(menuKeys[OTHER_MENU_KEY])
    )
    Assert.isNil(menuKeys[MENU_KEY], "the default menu key must not be hard-coded when the manifest names another")
  end, debug.traceback)
  game2:close()
  if not ok2 then
    error(err2, 0)
  end
end

return T
