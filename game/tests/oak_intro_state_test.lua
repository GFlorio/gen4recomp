-- Presentation boundary tests for shared Oak geometry, host input ownership,
-- and disposal. The controller/renderer are conforming test doubles so this
-- suite isolates the LÖVE callback adapter.

local Assert = require("tests.support.Assert")
local OakIntroState = require("game.src.game.OakIntroState")
local OakIntroController = require("game.src.game.OakIntroController")
local NewGame = require("game.src.game.NewGame")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")

local T = {}
local DIALOGUE_CURSOR_PLACEMENT = { x = 240, y = 168, width = 16, height = 16 }

---@class OakIntroStateTest.Controller
---@field phase string
---@field pressed string[]
---@field text string[]
---@field deleted integer
---@field started integer
---@field disposed integer
---@field choice table?
---@field compositionProgress number
---@field start fun(self: OakIntroStateTest.Controller)
---@field tick fun(self: OakIntroStateTest.Controller, frames: number)
---@field press fun(self: OakIntroStateTest.Controller, action: string)
---@field inputText fun(self: OakIntroStateTest.Controller, text: string)
---@field deleteGlyph fun(self: OakIntroStateTest.Controller)
---@field result fun(self: OakIntroStateTest.Controller): table?
---@field dispose fun(self: OakIntroStateTest.Controller)
---@field view fun(self: OakIntroStateTest.Controller): table
---@field messageCompleted fun(self: OakIntroStateTest.Controller, key: string)
---@class OakIntroStateTest.Input: OakIntroStateTextInputHost
---@field calls boolean[]
---@field setTextInput fun(self: OakIntroStateTest.Input, enabled: boolean)
---@class OakIntroStateTest.Renderer: OakIntroStateRenderer
---@field draws integer
---@field disposed integer
---@field draw fun(self: OakIntroStateTest.Renderer, view: table)
---@field dispose fun(self: OakIntroStateTest.Renderer)

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

---@return OakIntroStateTest.Controller
local function fakeController()
  local controller = {
    phase = "name_edit",
    pressed = {},
    text = {},
    deleted = 0,
    started = 0,
    disposed = 0,
    choice = nil,
    compositionProgress = 1,
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
      genderCompositionProgress = self.compositionProgress,
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
  return controller --[[@as OakIntroStateTest.Controller]]
end

local function stateHarness()
  local controller = fakeController()
  local input = { calls = {} }
  ---@cast input OakIntroStateTest.Input
  function input:setTextInput(enabled)
    self.calls[#self.calls + 1] = enabled
  end
  local renderer = { draws = 0, disposed = 0 }
  ---@cast renderer OakIntroStateTest.Renderer
  function renderer:draw()
    self.draws = self.draws + 1
  end
  function renderer:dispose()
    self.disposed = self.disposed + 1
  end
  local state = OakIntroState.new({
    controller = controller --[[@as OakIntroController]],
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
    dialogueCursorPlacement = DIALOGUE_CURSOR_PLACEMENT,
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

function T.pointer_cannot_activate_gender_selection_during_host_composition()
  local state, controller = stateHarness()
  controller.phase = "gender_composition_transition"
  controller.compositionProgress = 0
  local layout = state:view().layout
  Assert.isNil(layout.genderHitRegions)
  state:mousepressed(320, 240, 1)
  state:touchpressed(1, 320, 240)
  Assert.deepEqual(controller.pressed, {})
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
  local state, controller, _, renderer = stateHarness()
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

-- Real-controller fixtures below drive `OakIntroState` through its actual
-- `update`/`draw` boundary, the same seam the running game uses.

local SHRINK_MANIFEST = {
  sourceReference = INTRO_MANIFEST.sourceReference,
  background = INTRO_MANIFEST.background,
  widgets = {
    oak = INTRO_MANIFEST.widgets.oak,
    gender_background = INTRO_MANIFEST.widgets.gender_background,
    gender_male = INTRO_MANIFEST.widgets.gender_male,
    gender_female = INTRO_MANIFEST.widgets.gender_female,
    male = {
      width = 96,
      height = 120,
      anchor = { x = 48, y = 120 },
      sourceBounds = { x = 36, y = 24, width = 96, height = 120 },
    },
    shrink_male = {
      width = 44,
      height = 68,
      anchor = { x = 22, y = 68 },
      sourceBounds = { x = 142, y = 70, width = 44, height = 68 },
    },
  },
}

local SHRINK_PLAYER_DATA_CONTEXT = {
  charmap = { A = 1, B = 2, C = 3, D = 4, E = 5, F = 6, G = 7, O = 8, L = 9, [" "] = 10 },
  frameIndexes = { [0] = true },
}

local SHRINK_MESSAGES = {
  ["greeting.day"] = "greeting.day",
  ["oak.welcome"] = "oak.welcome",
  ["oak.world_inhabited"] = "oak.world_inhabited",
  ["oak.live_alongside"] = "oak.live_alongside",
  ["oak.tell_about_yourself"] = "oak.tell_about_yourself",
  ["profile.gender_question"] = "profile.gender_question",
  ["profile.gender_confirm.male"] = "profile.gender_confirm.male",
  ["profile.name_prompt"] = "profile.name_prompt",
  ["profile.name_confirm.male"] = "profile.name_confirm.male",
  ["profile.final"] = "profile.final",
}

local function silentAudio()
  return {
    playMusic = function() end,
    stopMusic = function() end,
    fadeMusicOut = function() end,
    play = function() end,
    playCry = function() end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function fixedClock()
  return {
    nowLocal = function()
      return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
    end,
  }
end

local function realCandidate()
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000099"
      end,
    },
    versionId = "heartgold",
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  })
end

local function shrinkFrames(duration, count)
  local frames = {}
  for index = 1, count do
    frames[index] = { duration = duration }
  end
  return { frames = frames }
end

-- Builds a real controller/state pair and drives it through the semantic
-- confirm presses used by production input mapping to the instant
-- `final_full_art_hold` is freshly entered with its 30-source-tick timer
-- untouched. The scenario body then drives the host-timed update boundary.
local function stateAtFreshFullArtHold(frameDuration, frameCount)
  local controller = OakIntroController.new({
    candidate = realCandidate(),
    clock = fixedClock(),
    audio = silentAudio() --[[@as GameSound]],
    messages = SHRINK_MESSAGES,
    assets = {
      marill = { frames = { { duration = 1 } } },
      marill_appear = { frames = { { duration = 1 } } },
      ball_open = { frames = { { duration = 1 } } },
      male = { frames = { { duration = 1 } } },
      shrink_male = shrinkFrames(frameDuration, frameCount),
    },
    virtualGlyphs = { "A", "B", "C", "D", "E", "F", "G", "O", "L" },
    playerDataContext = SHRINK_PLAYER_DATA_CONTEXT,
    randomU32 = function()
      return 0x12345678
    end,
  })

  local recorded = {}
  local renderer = {
    draw = function(_, view)
      recorded[#recorded + 1] = { phase = view.phase, visual = view.visual, frameIndex = view.visualFrameIndex }
    end,
    dispose = function() end,
  }
  local state = OakIntroState.new({
    controller = controller,
    manifest = SHRINK_MANIFEST,
    textRenderer = {},
    renderer = renderer,
    glyphs = { "A", "B", "C", "D", "E", "F", "G", "O", "L" },
    width = 640,
    height = 480,
  })

  state:tick(40)
  controller:press("confirm")
  state:tick(6 + 30)
  controller:press("confirm")
  state:tick(26)
  controller:press("confirm")
  while controller:view().phase ~= "oak_live_alongside" do
    state:tick(1)
  end
  controller:press("confirm")
  while controller:view().phase ~= "oak_tell_about_yourself" do
    state:tick(1)
  end
  controller:press("confirm")
  controller:press("confirm")
  state:tick(26)
  controller:press("confirm")
  controller:press("confirm")
  controller:press("confirm")
  state:tick(40)
  controller:inputText("GOLD")
  controller:press("submit")
  state:tick(26)
  controller:press("confirm")
  controller:press("confirm")
  Assert.equal(controller:view().phase, "final_fade_out")
  state:tick(1)
  Assert.equal(controller:view().phase, "final_full_art_fade_in")
  state:tick(1)
  Assert.equal(controller:view().phase, "final_full_art_hold")

  return state, controller, recorded
end

-- A normal 1/30 update/draw cadence preserves the exact 30-source-tick hold
-- and nine-source-tick-per-frame shrink cadence at the draw-visible
-- boundary.
function T.source_timed_update_draw_cadence_preserves_full_art_hold_and_shrink_frame_durations()
  local state, controller, recorded = stateAtFreshFullArtHold(9, 4)

  -- The setup above reaches the hold's freshly entered state through the
  -- frame-counted `tick` helper, which draws nothing; include that initial
  -- hold view before the first source-timed update.
  state:draw()

  for _ = 1, 30 + 9 * 4 do
    state:update(1 / 30)
    state:draw()
  end

  local holdDraws = 0
  for _, entry in ipairs(recorded) do
    if entry.phase == "final_full_art_hold" then
      holdDraws = holdDraws + 1
    end
  end
  Assert.equal(holdDraws, 30, "full profile art must remain draw-visible for exactly 30 source ticks")

  for frameIndex = 1, 4 do
    local draws = 0
    for _, entry in ipairs(recorded) do
      if entry.phase == "shrink_animation" and entry.frameIndex == frameIndex then
        draws = draws + 1
      end
    end
    Assert.equal(draws, 9, "each generated shrink frame must remain draw-visible for exactly nine source ticks")
  end

  Assert.equal(controller:view().phase, "complete")
end

function T.thirty_source_frame_hold_uses_one_second_host_time()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local holdStart = controller:view().sourceFrames

  for _ = 1, 29 do
    state:update(1 / 30)
    Assert.equal(controller:view().phase, "final_full_art_hold")
  end
  Assert.equal(controller:view().sourceFrames - holdStart, 29)

  state:update(1 / 30)

  Assert.equal(controller:view().sourceFrames - holdStart, 30)
  Assert.equal(controller:view().phase, "shrink_animation")
  Assert.equal(controller:view().visualFrameIndex, 1)
end

local function semanticSnapshot(controller)
  local view = controller:view()
  return {
    sourceFrames = view.sourceFrames,
    phase = view.phase,
    visual = view.visual,
    visualFrameIndex = view.visualFrameIndex,
    result = controller:result(),
  }
end

-- A host update that contains many source frames must have the same semantic
-- result as advancing those source frames directly, including transitions
-- across the full-art hold and several generated shrink frames.
function T.large_host_update_matches_equivalent_source_ticks()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local referenceState, referenceController = stateAtFreshFullArtHold(9, 4)

  state:update(52 / 30)
  referenceState:tick(52)

  Assert.deepEqual(
    semanticSnapshot(controller),
    semanticSnapshot(referenceController),
    "a large host update must drain the same source frames as the deterministic tick helper"
  )
end

function T.sub_source_frame_update_does_not_advance_the_controller()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local sourceFrames = controller:view().sourceFrames

  state:update(1 / 30 - 1e-13)

  Assert.equal(controller:view().sourceFrames, sourceFrames)
end

function T.two_half_source_frame_updates_drain_one_controller_tick()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local sourceFrames = controller:view().sourceFrames
  local halfSourceFrame = (1 / 30) / 2

  state:update(halfSourceFrame)
  Assert.equal(controller:view().sourceFrames, sourceFrames)

  state:update(halfSourceFrame)
  Assert.equal(controller:view().sourceFrames, sourceFrames + 1)
end

function T.completion_preserves_unconsumed_host_time_and_hands_off_once()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local completions = 0
  state.onComplete = function()
    completions = completions + 1
  end

  state:update(5)

  Assert.equal(controller:view().phase, "complete")
  Assert.isTrue(state.accumulator > 0)
  Assert.equal(completions, 1)
end

-- Drawing must not alter the semantic state that a later host update drains.
-- The second update crosses completion so the handoff remains a single
-- semantic event in both draw/no-draw paths.
function T.draw_cadence_does_not_change_semantic_progress()
  local drawnState, drawnController = stateAtFreshFullArtHold(9, 4)
  local undrawnState, undrawnController = stateAtFreshFullArtHold(9, 4)
  local drawnCompletions = 0
  local undrawnCompletions = 0
  drawnState.onComplete = function()
    drawnCompletions = drawnCompletions + 1
  end
  undrawnState.onComplete = function()
    undrawnCompletions = undrawnCompletions + 1
  end

  local initial = semanticSnapshot(drawnController)
  Assert.deepEqual(initial, semanticSnapshot(undrawnController))
  drawnState:draw()
  Assert.deepEqual(semanticSnapshot(drawnController), initial, "drawing must not advance the controller source clock")

  for _, dt in ipairs({ 1, 37 / 30 }) do
    drawnState:update(dt)
    undrawnState:update(dt)
    Assert.deepEqual(
      semanticSnapshot(drawnController),
      semanticSnapshot(undrawnController),
      "matching host updates must produce matching semantics regardless of draw cadence"
    )
  end

  Assert.equal(drawnCompletions, 1)
  Assert.equal(undrawnCompletions, 1)
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
      genderCompositionProgress = 1,
      name = "",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "background",
      virtualKeys = {},
    }
  end
  controller.messageCompleted = function(_, key)
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
