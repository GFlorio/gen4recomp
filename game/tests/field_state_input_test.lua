-- FieldState translates every physical direction into FieldInput's single
-- source-aware cardinal input path.

local Assert = require("tests.support.Assert")
local FieldState = require("game.src.game.FieldState")
local FieldInput = require("libs.engine.src.FieldInput")

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
    "pressMenu",
    "releaseMenu",
  }) do
    input[name] = function(_, ...)
      calls[#calls + 1] = { name, ... }
    end
  end
  return setmetatable(
    { runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = { m = true } } },
    FieldState
  )
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

function T.focus_loss_discards_stale_stick_axes_before_refocus()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = {} } }, FieldState)

  state:gamepadaxis(joystick, "leftx", -0.75)
  state:focus(false)
  state:gamepadaxis(joystick, "lefty", 0.25)

  Assert.deepEqual(input:uiSnapshot(1), {})
end

function T.focus_loss_does_not_leave_a_keyboard_direction_stuck_after_refocus()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = {} } }, FieldState)

  state:keypressed("down")
  state:focus(false)
  state:keypressed("right")
  state:keyreleased("right")

  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, pressedDirection = "east", actionDown = false, cancelDown = false, menuDown = false }
  )
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.gamepad_dpad_and_left_stick_drive_normal_field_movement()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = {} } }, FieldState)

  state:gamepadpressed(joystick, "dpdown")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "south", pressedDirection = "south", actionDown = false, cancelDown = false, menuDown = false }
  )
  state:gamepadreleased(joystick, "dpdown")
  state:gamepadaxis(joystick, "leftx", -0.75)
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "west", pressedDirection = "west", actionDown = false, cancelDown = false, menuDown = false }
  )
end

function T.keyboard_menu_key_and_gamepad_west_face_drive_the_semantic_menu_button()
  local calls = {}
  local state = stateWithInput(calls)
  state:keypressed("m")
  state:keyreleased("m")
  state:gamepadpressed(joystick, "x")
  state:gamepadreleased(joystick, "x")
  Assert.deepEqual(calls, {
    { "pressMenu", "key:m" },
    { "releaseMenu", "key:m" },
    { "pressMenu", "gamepad:7:x" },
    { "releaseMenu", "gamepad:7:x" },
  })
end

function T.the_menu_binding_follows_the_manifest_key_table()
  local calls = {}
  local state = stateWithInput(calls)
  state.runtime.menuKeys = { n = true }
  state:keypressed("m")
  state:keypressed("n")
  Assert.deepEqual(calls, {
    { "pressMenu", "key:n" },
  })
end

function T.menu_button_edges_reach_the_runtime_input_source_aware_model()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = { m = true } } }, FieldState)

  state:keypressed("m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true, menuPressed = true }
  )
  state:keypressed("m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true },
    "a repeat press of the held menu key produces no second edge"
  )
  state:keyreleased("m")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

return { tests = T }
