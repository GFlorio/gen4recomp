-- Presentation boundary tests for shared Oak geometry, host input ownership,
-- and disposal. The controller/renderer are conforming test doubles so this
-- suite isolates the LÖVE callback adapter.

local Assert = require("tests.support.Assert")
local OakIntroState = require("game.src.game.OakIntroState")

local T = {}

local function fakeController()
  local controller = {
    phase = "name_edit",
    pressed = {},
    text = {},
    deleted = 0,
    started = 0,
    disposed = 0,
  }
  function controller:start()
    self.started = self.started + 1
  end
  function controller:tick() end
  function controller:press(action)
    self.pressed[#self.pressed + 1] = action
  end
  function controller:inputText(text)
    self.text[#self.text + 1] = text
  end
  function controller:deleteGlyph()
    self.deleted = self.deleted + 1
  end
  function controller:result()
    return nil
  end
  function controller:dispose()
    self.disposed = self.disposed + 1
  end
  function controller:view()
    return {
      phase = self.phase,
      name = "A",
      nameInputEnabled = self.phase == "name_edit",
      genderFocus = 0,
      message = "generated.message",
      visual = "background",
      virtualKeys = {
        { kind = "glyph", glyph = "A" },
        { kind = "glyph", glyph = "B" },
        { kind = "glyph", glyph = "é" },
        { kind = "delete" },
        { kind = "confirm" },
      },
      virtualKeyColumns = 3,
    }
  end
  return controller
end

local function stateHarness()
  local controller = fakeController()
  local input = { calls = {} }
  function input:setTextInput(enabled)
    self.calls[#self.calls + 1] = enabled
  end
  local renderer = { draws = 0, disposed = 0 }
  function renderer:draw()
    self.draws = self.draws + 1
  end
  function renderer:dispose()
    self.disposed = self.disposed + 1
  end
  local state = OakIntroState.new({
    controller = controller,
    manifest = {},
    renderer = renderer,
    textInputHost = input,
    glyphs = { "A", "B", "é" },
    width = 640,
    height = 480,
  })
  return state, controller, input, renderer
end

function T.text_input_is_owned_only_by_the_name_editor_and_released_on_dispose()
  local state, controller, input, renderer = stateHarness()
  Assert.deepEqual(input.calls, { false })
  state:textinput("é")
  Assert.deepEqual(input.calls, { false, true })
  Assert.deepEqual(controller.text, { "é" })
  controller.phase = "gender_select"
  state:update(0)
  Assert.deepEqual(input.calls, { false, true, false })
  state:dispose()
  Assert.deepEqual(input.calls, { false, true, false })
  Assert.equal(controller.disposed, 1)
  Assert.equal(renderer.disposed, 1)
end

function T.pointer_hits_the_same_drawn_virtual_key_geometry()
  local state, controller = stateHarness()
  local layout = state:view().layout
  local key = layout.nameGrid[3].rect
  state:mousepressed(key.x + 1, key.y + 1, 1)
  Assert.deepEqual(controller.text, { "é" })
end

function T.keyboard_and_gamepad_use_one_controller_buffer_path()
  local state, controller = stateHarness()
  state:keypressed("right")
  state:gamepadpressed({}, "a")
  state:keypressed("backspace")
  Assert.deepEqual(controller.pressed, { "right", "confirm" })
  Assert.equal(controller.deleted, 1)
  Assert.deepEqual(controller.text, {})
end

function T.gamepad_confirm_uses_the_focused_semantic_key()
  local state, controller = stateHarness()
  state:gamepadpressed(nil, "a")
  controller.phase = "gender_select"
  state:gamepadpressed(nil, "a")
  Assert.deepEqual(controller.pressed, { "confirm", "confirm" })
end

function T.return_uses_the_shared_confirm_action()
  local state, controller = stateHarness()
  state:keypressed("return")
  state:keypressed("kpenter")
  state:keypressed("space")
  Assert.deepEqual(controller.pressed, { "submit", "submit", "submit" })
end

function T.audio_lifetime_is_released_once_with_the_state()
  local state, controller, input, renderer = stateHarness()
  local lifetime = { releases = 0 }
  function lifetime:dispose()
    self.releases = self.releases + 1
  end
  state.audioLifetime = lifetime

  state:dispose()
  state:dispose()

  Assert.equal(lifetime.releases, 1)
  Assert.equal(controller.disposed, 1)
  Assert.equal(renderer.disposed, 1)
end

return { tests = T }
