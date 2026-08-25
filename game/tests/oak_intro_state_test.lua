-- Presentation boundary tests for shared Oak geometry, host input ownership,
-- and disposal. The controller/renderer are conforming test doubles so this
-- suite isolates the LÖVE callback adapter.

local Assert = require("tests.support.Assert")
local OakIntroState = require("game.src.game.OakIntroState")

local T = {}

local INTRO_MANIFEST = {
  sourceReference = { width = 256, height = 192 },
  background = { width = 256, height = 192, sampling = "linear" },
  widgets = {
    oak = {
      width = 80,
      height = 100,
      anchor = { x = 20, y = 100 },
      sourceBounds = { x = 40, y = 30, width = 80, height = 100 },
    },
    gender_background = {
      width = 256,
      height = 192,
      anchor = { x = 128, y = 192 },
      sourceBounds = { x = 0, y = 0, width = 256, height = 192 },
    },
    gender_male = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
      sourceCenter = { x = 64, y = 104 },
    },
    gender_female = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
      sourceCenter = { x = 192, y = 104 },
    },
  },
}

local function fakeController()
  local controller = {
    phase = "name_edit",
    pressed = {},
    text = {},
    deleted = 0,
    started = 0,
    disposed = 0,
    choice = nil,
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
      confirmationChoice = self.choice,
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
    manifest = INTRO_MANIFEST,
    textRenderer = {},
    renderer = renderer,
    textInputHost = input,
    dialogueFormatter = {
      format = function(_, key)
        return { tokens = {}, text = key, hadUnresolvedSubstitutions = false }
      end,
      choiceLabels = function()
        return { [0] = "YES", [1] = "NO" }
      end,
    },
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

function T.pointer_hits_the_same_choice_rows_used_by_presentation()
  local state, controller = stateHarness()
  controller.phase = "gender_confirm"
  controller.choice = { kind = "gender", selected = 0 }
  local layout = state:view().layout
  state:mousepressed(layout.choiceRows[0].x + 1, layout.choiceRows[0].y + 1, 1)
  state:mousepressed(layout.choiceRows[1].x + 1, layout.choiceRows[1].y + 1, 1)
  Assert.deepEqual(controller.pressed, { "yes", "no" })
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

function T.confirm_capable_keys_activate_the_focused_virtual_key_like_gamepad_a()
  local state, controller = stateHarness()
  Assert.equal(controller.phase, "name_edit")
  state:keypressed("return")
  state:keypressed("kpenter")
  state:keypressed("space")
  state:gamepadpressed(nil, "a")
  Assert.deepEqual(
    controller.pressed,
    { "confirm", "confirm", "confirm", "confirm" },
    "keyboard Enter/KPEnter/Space must send the same focused-key action as gamepad A, never a direct submit"
  )
end

function T.a_held_confirm_key_does_not_repeat_activation()
  local state, controller = stateHarness()
  state:keypressed("return", "return", false)
  state:keypressed("return", "return", true)
  state:keypressed("return", "return", true)
  Assert.deepEqual(
    controller.pressed,
    { "confirm" },
    "a held physical key must not activate the focused virtual key more than once"
  )
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

function T.shared_dialogue_stack_is_advanced_and_drawn_by_the_state()
  local state, controller = stateHarness()
  local dialogue = {
    opened = 0,
    stepped = 0,
    drawn = 0,
    released = 0,
    open = function(self)
      self.opened = self.opened + 1
      return { onComplete = function() end }
    end,
    step = function(self, input)
      self.stepped = self.stepped + 1
      self.lastInput = input
    end,
    isModal = function()
      return true
    end,
    status = function()
      return {}
    end,
    draw = function(self, presentation)
      self.drawn = self.drawn + 1
      self.presentation = presentation
    end,
    dispose = function(self)
      self.released = self.released + 1
    end,
  }
  state.dialogueController = dialogue
  state.dialogueRenderer = dialogue
  state.dialoguePresentation = nil
  controller.phase = "oak_welcome"
  controller.view = function(self)
    return {
      phase = self.phase,
      messageKey = "oak.welcome",
      message = { tokens = {} },
      name = "",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "background",
      virtualKeys = {},
    }
  end
  state:_sync()
  Assert.equal(dialogue.opened, 1)
  state:tick(1)
  Assert.equal(dialogue.stepped, 1)
  state:draw()
  Assert.equal(dialogue.drawn, 1)
  Assert.notNil(dialogue.presentation, "Oak passes its compact dialogue presentation to the shared renderer")
  state:dispose()
  Assert.equal(dialogue.released, 1)
end

function T.dialogue_completion_edge_does_not_enter_the_new_choice()
  local state, controller = stateHarness()
  local modal = true
  local completion
  controller.phase = "gender_confirm"
  controller.view = function(self)
    return {
      phase = self.phase,
      messageKey = modal and "profile.gender_confirm.male" or nil,
      message = modal and { tokens = {} } or nil,
      confirmationChoice = not modal and { kind = "gender", selected = 0 } or nil,
      name = "",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "background",
      virtualKeys = {},
    }
  end
  controller.messageCompleted = function(self, key)
    Assert.equal(key, "profile.gender_confirm.male")
    modal = false
  end
  local dialogue = {
    open = function()
      return {
        onComplete = function(_, callback)
          completion = callback
        end,
      }
    end,
    step = function()
      if completion then
        local callback = completion
        completion = nil
        modal = false
        callback()
      end
    end,
    isModal = function()
      return modal
    end,
    status = function()
      return {}
    end,
  }
  state.dialogueController = dialogue
  state:_sync()
  state:keypressed("return")
  Assert.deepEqual(controller.pressed, {})
  Assert.notNil(state:view().confirmationChoice)
end

return { tests = T }
