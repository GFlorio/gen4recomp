-- FieldState translates every physical direction into FieldInput's single
-- source-aware cardinal input path.

local Assert = require("tests.support.Assert")
local FieldState = require("game.src.game.FieldState")

local T = {}

local function stateWithInput(calls)
  local input = {}
  for _, name in ipairs({
    "pressDirection",
    "releaseDirection",
    "setStickAxis",
    "pointerDown",
    "pointerMove",
    "pointerUp",
    "pointerScroll",
  }) do
    input[name] = function(_, ...)
      calls[#calls + 1] = { name, ... }
    end
  end
  return setmetatable({ input = input }, FieldState)
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
    { "pressDirection", "south", "key:down" },
    { "releaseDirection", "key:down" },
    { "pressDirection", "north", "gamepad:7:dpup" },
    { "releaseDirection", "gamepad:7:dpup" },
    { "setStickAxis", "gamepad:7:left", "x", -0.75 },
    { "setStickAxis", "gamepad:7:left", "y", 0.25 },
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

function T.releasing_one_of_two_keys_for_the_same_direction_releases_its_own_source()
  local calls = {}
  local state = stateWithInput(calls)

  state:keypressed("w")
  state:keypressed("up")
  state:keyreleased("w")

  Assert.deepEqual(calls, {
    { "pressDirection", "north", "key:w" },
    { "pressDirection", "north", "key:up" },
    { "releaseDirection", "key:w" },
  })
end

return T
