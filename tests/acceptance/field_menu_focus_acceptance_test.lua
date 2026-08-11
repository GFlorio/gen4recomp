-- Production-composed field-menu focus contracts. These scenarios execute a
-- real generated HGSS menu through FieldRuntime, use the actual FieldInput
-- normalization path, and stop before any draw call.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "menu", "input", "focus", "script" },
  },
  tests = {},
}

-- This compact three-choice vanilla menu is a source-faithful 749--752 flow.
-- Its second value is 1, so selection is observably distinct from both the
-- initial row and the source-message id.
local VANILLA_MENU = "vanilla.hgss.scr_seq.0003.script_056"
local SPECIAL_RESULT = 32780

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function menuIsModal(snapshot)
  return snapshot.menu ~= nil and snapshot.menu.modal == true
end

local function openVanillaMenu(game)
  game:startScript(VANILLA_MENU)
  return game:advanceUntil("vanilla field menu becomes modal", menuIsModal, 120)
end

local function pressConfirm(game, source)
  game.runtime.input:pressAction(source)
  game:step()
  game.runtime.input:releaseAction(source)
end

local function pressUi(game, direction, source)
  game.runtime.input:pressUi(direction, source)
  game:step()
  game.runtime.input:releaseUi(direction, source)
end

local function itemCenter(snapshot, itemIndex)
  local menu = assert(snapshot.menu, "field menu snapshot is required")
  local rect = assert(menu.itemRects[itemIndex], "field menu item rectangle is required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function selectSecondItem(game, modality)
  local opened = openVanillaMenu(game)
  if modality == "keyboard" then
    pressUi(game, "down", "key:s")
    pressConfirm(game, "key:return")
  elseif modality == "gamepad" then
    game.runtime.input:setUiStick("gamepad:1:left", 0, 1)
    game:step()
    game.runtime.input:setUiStick("gamepad:1:left", 0, 0)
    pressConfirm(game, "gamepad:1:a")
  elseif modality == "mouse" then
    local x, y = itemCenter(opened, 1)
    game.runtime.input:pointerDown("mouse:1", x, y)
    game:step()
    game.runtime.input:pointerUp("mouse:1", x, y)
    game:step()
  elseif modality == "touch" then
    local x, y = itemCenter(opened, 1)
    game.runtime.input:pointerDown("touch:0", x, y)
    game:step()
    game.runtime.input:pointerUp("touch:0", x, y)
    game:step()
  else
    error("unknown menu modality " .. tostring(modality))
  end
  game:advanceUntil("field menu closes after selection", function(snapshot)
    return snapshot.menu ~= nil and not snapshot.menu.modal
  end, 120)
  return game.runtime.scripts.worldState:getVar(SPECIAL_RESULT)
end

-- FM-12-01: every physical modality must reach the same controller and write
-- the script-owned value, never its visual row number or source message id.
function T.tests.vanilla_menu_selection_has_one_result_across_input_modalities()
  for _, modality in ipairs({ "keyboard", "gamepad", "mouse", "touch" }) do
    withGame(function(game)
      Assert.equal(selectSecondItem(game, modality), 1, modality .. " must select the vanilla value")
    end)
  end
end

-- FM-12-02: the Action edge that completes a menu is consumed by the modal
-- owner. Once the menu branch releases, that old edge cannot start a field
-- interaction on the following fixed tick.
function T.tests.menu_closing_confirm_does_not_leak_to_field_interaction()
  withGame(function(game)
    selectSecondItem(game, "keyboard")
    game:step()
    Assert.isNil(game:interaction().scriptId)
  end)
end

return T
