-- FieldState translates physical LÖVE events into FieldInput's menu-neutral
-- UI events while retaining the legacy field controls.

local Assert = require("tests.support.Assert")
local FieldState = require("game.src.game.FieldState")

local T = {}

local function stateWithInput(calls)
  local input = {}
  for _, name in ipairs({
    "press",
    "release",
    "pressUi",
    "releaseUi",
    "setUiStick",
    "pointerDown",
    "pointerMove",
    "pointerUp",
    "pointerScroll",
  }) do
    input[name] = function(_, ...)
      calls[#calls + 1] = { name, ... }
    end
  end
  return setmetatable({ input = input, heldDirectionKeys = {} }, FieldState)
end

local joystick = {
  getID = function()
    return 7
  end,
}

function T.keyboard_dpad_stick_and_pointer_events_reach_the_unified_input()
  local calls = {}
  local state = stateWithInput(calls)

  state:keypressed("down")
  state:keyreleased("down")
  state:gamepadpressed(joystick, "dpup")
  state:gamepadreleased(joystick, "dpup")
  state:gamepadaxis(joystick, "leftx", -0.75)
  state:gamepadaxis(joystick, "lefty", 0.25)
  state:mousepressed(12, 34, 1)
  state:mousemoved(15, 36, 3, 2, false)
  state:mousereleased(15, 36, 1)
  state:wheelmoved(2, -3)
  state:touchpressed(9, 3, 4)
  state:touchmoved(9, 5, 6)
  state:touchreleased(9, 5, 6)

  Assert.deepEqual(calls, {
    { "press", "south" },
    { "pressUi", "down", "key:down" },
    { "release", "south" },
    { "releaseUi", "down", "key:down" },
    { "pressUi", "up", "gamepad:7:dpup" },
    { "releaseUi", "up", "gamepad:7:dpup" },
    { "setUiStick", "gamepad:7:left", -0.75, 0 },
    { "setUiStick", "gamepad:7:left", -0.75, 0.25 },
    { "pointerDown", "mouse:1", 12, 34 },
    { "pointerMove", "mouse:1", 15, 36 },
    { "pointerUp", "mouse:1", 15, 36 },
    { "pointerScroll", "mouse", 2, -3 },
    { "pointerDown", "touch:9", 3, 4 },
    { "pointerMove", "touch:9", 5, 6 },
    { "pointerUp", "touch:9", 5, 6 },
  })
end

function T.only_the_primary_mouse_button_drives_menu_pointer_activation()
  local calls = {}
  local state = stateWithInput(calls)

  state:mousepressed(12, 34, 2)
  state:mousemoved(15, 36, 3, 2, true)
  state:mousereleased(15, 36, 2)

  Assert.deepEqual(calls, {})
end

function T.releasing_one_of_two_keys_for_the_same_ui_direction_releases_its_own_source()
  local calls = {}
  local state = stateWithInput(calls)

  state:keypressed("w")
  state:keypressed("up")
  state:keyreleased("w")

  Assert.deepEqual(calls, {
    { "press", "north" },
    { "pressUi", "up", "key:w" },
    { "press", "north" },
    { "pressUi", "up", "key:up" },
    { "releaseUi", "up", "key:w" },
  })
end

return T
