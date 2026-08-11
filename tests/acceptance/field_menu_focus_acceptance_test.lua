-- Production-composed field-menu focus contracts. These scenarios execute a
-- real generated HGSS menu through FieldRuntime, use the actual FieldInput
-- normalization path, and stop before any draw call.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldState = require("game.src.game.FieldState")

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

local joystick = {
  getID = function()
    return 1
  end,
}

-- Acceptance owns the non-rendering runtime, while this thin host adapter
-- invokes the same FieldState callbacks that LÖVE dispatches in production.
-- It deliberately has no synthetic input behavior of its own.
local function hostCallbacks(game)
  return setmetatable({ input = game.runtime.input }, FieldState)
end

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

local function pressKey(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

local function pressDpad(game, state, button)
  state:gamepadpressed(joystick, button)
  game:step()
  state:gamepadreleased(joystick, button)
end

local function itemCenter(snapshot, itemIndex)
  local menu = assert(snapshot.menu, "field menu snapshot is required")
  local rect = assert(menu.itemRects[itemIndex], "field menu item rectangle is required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function selectSecondItem(game, modality)
  local opened = openVanillaMenu(game)
  local state = hostCallbacks(game)
  if modality == "keyboard" then
    pressKey(game, state, "s")
    pressConfirm(game, "key:return")
  elseif modality == "gamepad" then
    state:gamepadpressed(joystick, "dpdown")
    game:step()
    state:gamepadreleased(joystick, "dpdown")
    pressConfirm(game, "gamepad:1:a")
  elseif modality == "mouse" then
    local x, y = itemCenter(opened, 1)
    state:mousepressed(x, y, 1)
    game:step()
    state:mousereleased(x, y, 1)
    game:step()
  elseif modality == "touch" then
    local x, y = itemCenter(opened, 1)
    state:touchpressed(0, x, y)
    game:step()
    state:touchreleased(0, x, y)
    game:step()
  else
    error("unknown menu modality " .. tostring(modality))
  end
  game:advanceUntil("field menu closes after selection", function(snapshot)
    return snapshot.menu ~= nil and not snapshot.menu.modal
  end, 120)
  return game.runtime.scripts.worldState:getVar(SPECIAL_RESULT)
end

-- D5-FIELD-01: D-pad input enters through the LÖVE host callback but must
-- move the same real player as keyboard input when no modal owner consumes it.
function T.tests.dpad_callback_moves_the_production_field_player()
  withGame(function(game)
    game:face("east")
    local state = hostCallbacks(game)
    state:gamepadpressed(joystick, "dpup")
    game:step()
    state:gamepadreleased(joystick, "dpup")

    Assert.equal(game:snapshot().player.facing, "north", "D-pad Up must reach field movement")
  end)
end

-- D5-FIELD-02: the left stick has the identical field contract through its
-- paired-axis host callback, including when only its vertical axis changes.
function T.tests.left_stick_callback_moves_the_production_field_player()
  withGame(function(game)
    game:face("east")
    local state = hostCallbacks(game)
    state:gamepadaxis(joystick, "lefty", -0.75)
    game:step()
    state:gamepadaxis(joystick, "lefty", 0)

    Assert.equal(game:snapshot().player.facing, "north", "left stick Up must reach field movement")
  end)
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

-- D6-NAV-01: a production single-column menu receives normalized keyboard and
-- D-pad directions through FieldState. Horizontal directions must leave its
-- script-owned focus unchanged; only the resolved layout may define a target.
function T.tests.single_column_menu_ignores_horizontal_keyboard_and_gamepad_navigation()
  for _, modality in ipairs({ "keyboard", "gamepad" }) do
    withGame(function(game)
      local state = hostCallbacks(game)
      openVanillaMenu(game)

      if modality == "keyboard" then
        pressKey(game, state, "s")
      else
        pressDpad(game, state, "dpdown")
      end
      Assert.equal(game:snapshot().menu.layout.selectedIndex, 1, modality .. " reaches the second row")

      if modality == "keyboard" then
        pressKey(game, state, "a")
      else
        pressDpad(game, state, "dpleft")
      end
      Assert.equal(game:snapshot().menu.layout.selectedIndex, 1, modality .. " Left is a no-op in one column")

      if modality == "keyboard" then
        pressKey(game, state, "d")
      else
        pressDpad(game, state, "dpright")
      end
      Assert.equal(game:snapshot().menu.layout.selectedIndex, 1, modality .. " Right is a no-op in one column")
    end)
  end
end

-- D3-HGSS-01: opcode 749 deliberately yields after creating its builder.
-- A process restart at that source-faithful boundary must retain the builder
-- in the foreground script instance, so the later 751/752 operations can
-- publish the same real menu and write its selected HGSS value.
function T.tests.restart_after_hgss_menu_begin_resumes_the_real_menu_builder()
  withGame(function(game)
    game:startScript(VANILLA_MENU)
    game:step()

    local resumed = game:restart({ save = "resume" })
    local opened = resumed:advanceUntil("resumed HGSS menu becomes modal", menuIsModal, 120)

    local x, y = itemCenter(opened, 1)
    resumed.runtime.input:pointerDown("mouse:1", x, y)
    resumed:step()
    resumed.runtime.input:pointerUp("mouse:1", x, y)
    resumed:advanceUntil("resumed HGSS menu closes after selection", function(snapshot)
      return snapshot.menu ~= nil and not snapshot.menu.modal
    end, 120)
    Assert.equal(resumed.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 1)
  end)
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
