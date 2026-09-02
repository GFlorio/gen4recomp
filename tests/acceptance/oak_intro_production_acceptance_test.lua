-- Product Oak acceptance: the concrete composition owner builds Oak from the
-- selected generated cache without an application-shell test factory.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local GameAudio = require("game.hgss.src.audio.GameAudio")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "oak", "product", "composition" },
  },
  tests = {},
}

local hostSeams

local function newCandidate(versionId)
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000001"
      end,
    },
    versionId = versionId,
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

local function recordingSound(sound, trace)
  local wrapped = {}

  function wrapped:playMusic(id)
    trace[#trace + 1] = { name = "music", value = id }
    return sound:playMusic(id)
  end

  function wrapped:stopMusic()
    trace[#trace + 1] = { name = "stop_music" }
    return sound:stopMusic()
  end

  function wrapped:fadeMusicOut(spec)
    trace[#trace + 1] = { name = "fade_out", value = spec }
    return sound:fadeMusicOut(spec)
  end

  function wrapped:play(id)
    trace[#trace + 1] = { name = "effect", value = id }
    return sound:play(id)
  end

  function wrapped:playCry(species, form)
    trace[#trace + 1] = { name = "cry", value = { species = species, form = form } }
    return sound:playCry(species, form)
  end

  function wrapped:updateSoundFrame()
    return sound:updateSoundFrame()
  end

  function wrapped:isMusicFadeActive()
    return sound:isMusicFadeActive()
  end

  return wrapped
end

local function withProductionOak(versionId, options, fn)
  if fn == nil then
    fn = options
    options = {}
  end
  local candidate = newCandidate(versionId)
  local host = hostSeams()
  local completion = {}
  local composeOptions = {
    candidate = candidate,
    versionId = versionId,
    onComplete = function(result)
      completion[#completion + 1] = result
    end,
  }
  for key, value in pairs(host) do
    composeOptions[key] = value
  end

  local audioTrace = options.recordAudio and {} or nil
  local originalAudioCompose = GameAudio.compose
  if audioTrace then
    rawset(GameAudio, "compose", function(audioComposeOptions)
      local composition = originalAudioCompose(audioComposeOptions)
      composition.sound = recordingSound(composition.sound, audioTrace) --[[@as GameSound]]
      return composition
    end)
  end

  local state
  local ok, err = xpcall(function()
    state = OakIntroComposition.compose(composeOptions)
    fn(state, host, completion, audioTrace)
  end, debug.traceback)

  rawset(GameAudio, "compose", originalAudioCompose)
  if state then
    state:dispose()
    Assert.isTrue(state.disposed, "the direct Oak composition must be disposed after each scenario")
  end
  if not ok then
    error(err, 0)
  end
end

local function assertOneSelectionEffect(trace, startIndex, message)
  local effects = {}
  for index = startIndex + 1, #trace do
    local event = trace[index]
    if event.name == "effect" and event.value == "SEQ_SE_DP_SELECT" then
      effects[#effects + 1] = event
    end
  end
  Assert.equal(#effects, 1, message .. " must emit one selection effect")
end

local function forEachReadyVersion(fn)
  local count = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      count = count + 1
      fn(versionId)
    end
  end
  Assert.isTrue(count > 0, "acceptance capability detection promised a ready ROM version")
end

local function finishDialogueBoundary(state)
  local initialKey = state:view().messageKey
  Assert.notNil(initialKey, "scenario requires an active Oak dialogue")
  for _ = 1, 12000 do
    local view = state:view()
    if view.messageKey ~= initialKey then
      return
    end
    local status = state.dialogueController:status()
    if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
      state:keypressed("return")
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not reach its semantic completion boundary: " .. tostring(initialKey))
end

-- Navigates keyboard focus onto the virtual Confirm key before activating
-- it, matching the one confirm-capable-device contract (keyboard/gamepad
-- both activate the focused virtual key rather than submitting directly).
local function submitName(state)
  state:keypressed("left")
  state:keypressed("return")
  state:tick(26)
end

local function advanceUntilMessage(state, messageKey)
  for _ = 1, 20000 do
    local view = state:view()
    if view.messageKey == messageKey then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogueBoundary(state)
    else
      state:tick(1)
    end
  end
  error("Oak message did not open: " .. messageKey)
end

local function advanceUntilPhase(state, phase)
  for _ = 1, 20000 do
    if state:view().phase == phase then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogueBoundary(state)
    else
      state:tick(1)
    end
  end
  error("Oak phase did not become: " .. phase)
end

local function enterGenderSelection(state)
  Assert.equal(state:view().phase, "gender_question")
  finishDialogueBoundary(state)
  local phase = state:view().phase
  if phase == "gender_composition_transition" or phase == "name_composition_return" then
    state:tick(26)
  end
  Assert.equal(state:view().phase, "gender_select")
end

local function reachNameConfirmation(state)
  advanceUntilMessage(state, "profile.gender_question")
  enterGenderSelection(state)
  state:keypressed("return")
  finishDialogueBoundary(state)
  state:keypressed("return")
  finishDialogueBoundary(state)
  advanceUntilPhase(state, "name_edit")
  state:textinput("GOLD")
  submitName(state)
  finishDialogueBoundary(state)
  Assert.equal(state:view().phase, "name_confirm")
end

local function assertResolvedMessage(state, messageKey, playerName)
  Assert.equal(state:view().messageKey, messageKey)
  for _ = 1, 2000 do
    local visibleText = {}
    for _, line in ipairs(state.dialogueController:status().visibleLines) do
      for _, token in ipairs(line) do
        if token.text then
          visibleText[#visibleText + 1] = token.text
        end
      end
    end
    if table.concat(visibleText):find(playerName, 1, true) then
      return
    end
    state.dialogueController:step()
  end
  error("Oak dialogue did not reveal the player name")
end

function T.tests.profile_choice_activation_uses_one_selection_effect_on_composed_paths()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, { recordAudio = true }, function(state, _, _, trace)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      local before = #trace
      state:keypressed("return")
      Assert.equal(state:view().phase, "gender_confirm")
      assertOneSelectionEffect(trace, before, "keyboard gender activation")

      finishDialogueBoundary(state)
      before = #trace
      state:keypressed("return")
      Assert.equal(state:view().phase, "name_prompt")
      assertOneSelectionEffect(trace, before, "keyboard Yes activation")

      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      submitName(state)
      finishDialogueBoundary(state)
      before = #trace
      state:keypressed("return")
      Assert.equal(state:view().phase, "final_dialogue")
      assertOneSelectionEffect(trace, before, "keyboard name confirmation")
    end)

    withProductionOak(versionId, { recordAudio = true }, function(state, _, _, trace)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      local before = #trace
      state:gamepadpressed({}, "a")
      Assert.equal(state:view().phase, "gender_confirm")
      assertOneSelectionEffect(trace, before, "gamepad gender activation")

      finishDialogueBoundary(state)
      before = #trace
      state.controller:press("no")
      Assert.equal(state:view().phase, "gender_question")
      assertOneSelectionEffect(trace, before, "direct No activation")
    end)

    withProductionOak(versionId, { recordAudio = true }, function(state, _, _, trace)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      local buttons = assert(state:view().layout.genderButtons)
      local female = assert(buttons[1])
      local rect = female.rect
      local before = #trace
      state:mousepressed(rect.x + rect.width / 2, rect.y + rect.height / 2, 1)
      Assert.equal(state:view().phase, "gender_confirm")
      assertOneSelectionEffect(trace, before, "pointer gender activation")
    end)

    withProductionOak(versionId, { recordAudio = true }, function(state, _, _, trace)
      reachNameConfirmation(state)
      local before = #trace
      state.controller:press("cancel")
      Assert.equal(state:view().phase, "gender_question")
      assertOneSelectionEffect(trace, before, "semantic cancel activation")
    end)
  end)
end

local function eventsNamed(state, kind)
  local events = {}
  for _, event in ipairs(state.controller:view().events) do
    if event.kind == kind then
      events[#events + 1] = event
    end
  end
  return events
end

local function durationTotal(frames)
  local total = 0
  for _, frame in ipairs(frames) do
    total = total + frame.duration
  end
  return total
end

local function reachFinalFullArtHold(state, female)
  advanceUntilMessage(state, "profile.gender_question")
  enterGenderSelection(state)
  if female then
    state:keypressed("right")
  end
  state:keypressed("return")
  finishDialogueBoundary(state)
  state:keypressed("return")
  finishDialogueBoundary(state)
  advanceUntilPhase(state, "name_edit")
  state:textinput("GOLD")
  submitName(state)
  finishDialogueBoundary(state)
  state:keypressed("return")
  finishDialogueBoundary(state)
  state:keypressed("return")
  advanceUntilPhase(state, "final_full_art_hold")
end

local function assertSubjectUsesOwnSourceGeometry(state, widgetId, width, height)
  state:resize(width, height)
  local view = state:view()
  Assert.equal(view.primaryWidget, widgetId, "the rendered profile visual must be the selected widget")
  local layout = assert(view.layout)
  local subject = assert(layout.subject)
  local widget = assert(state.manifest.widgets[widgetId])
  local canvas = assert(layout.sourceCanvas)
  Assert.near(subject.width, widget.width * canvas.scale, 1e-6, widgetId .. " width must use its generated geometry")
  Assert.near(subject.height, widget.height * canvas.scale, 1e-6, widgetId .. " height must use its generated geometry")
  local sourceX = (subject.x + widget.anchor.x * subject.scale - canvas.origin.x) / canvas.scale
  local sourceY = (subject.y + widget.anchor.y * subject.scale - canvas.origin.y) / canvas.scale
  Assert.near(
    sourceX,
    widget.sourceBounds.x + widget.anchor.x,
    1e-6,
    widgetId .. " anchor must map to its generated source X"
  )
  Assert.near(
    sourceY,
    widget.sourceBounds.y + widget.anchor.y,
    1e-6,
    widgetId .. " anchor must map to its generated source Y"
  )
  return view, { x = sourceX, y = sourceY }
end

hostSeams = function()
  local image = {}
  function image:getWidth()
    return 256
  end
  function image:getHeight()
    return 192
  end
  function image:setFilter() end
  function image:release() end

  local graphics = FakeGraphics.new()
  local audio = FakeAudioOutput.new()
  local textInputCalls = {}
  return {
    graphics = graphics,
    imageLoader = function()
      return image
    end,
    audioOutput = { audio = audio.audio, sound = audio.sound },
    clock = {
      nowLocal = function()
        return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
      end,
    },
    randomU32 = function()
      return 0x12345678
    end,
    textInputHost = {
      setTextInput = function(_, enabled)
        textInputCalls[#textInputCalls + 1] = enabled
      end,
    },
    textInputCalls = textInputCalls,
  }
end

function T.tests.new_game_enters_production_oak_without_a_factory()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state)
      Assert.equal(state.controller:candidate().saveId, "save-00000001")
    end)
  end)
end

function T.tests.confirmation_text_requires_a_later_explicit_choice_edge()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      state:keypressed("return")
      Assert.equal(state:view().messageKey, "profile.gender_confirm.male")

      finishDialogueBoundary(state)
      local view = state:view()
      Assert.equal(view.phase, "gender_confirm")
      Assert.equal(view.confirmationChoice.selected, 0)

      state:keypressed("down")
      state:keypressed("escape")
      Assert.equal(state:view().phase, "gender_question")

      enterGenderSelection(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      Assert.equal(state:view().phase, "gender_confirm")
      state:keypressed("return")
      Assert.equal(state:view().phase, "name_prompt")

      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      submitName(state)
      finishDialogueBoundary(state)
      Assert.equal(state:view().phase, "name_confirm")
      Assert.equal(state:view().confirmationChoice.selected, 0)
      state:keypressed("escape")
      Assert.equal(state:view().phase, "gender_question")
    end)
  end)
end

function T.tests.player_name_is_formatted_when_each_confirmation_message_opens()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      state:keypressed("right")
      state:keypressed("return")
      finishDialogueBoundary(state)
      Assert.equal(state:view().phase, "gender_confirm")
      state:keypressed("return")

      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      submitName(state)
      assertResolvedMessage(state, "profile.name_confirm.female", "GOLD")
      finishDialogueBoundary(state)
      state:keypressed("escape")

      enterGenderSelection(state)
      state:keypressed("left")
      state:keypressed("return")
      finishDialogueBoundary(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      submitName(state)
      assertResolvedMessage(state, "profile.name_confirm.male", "GOLD")
      finishDialogueBoundary(state)
      state:keypressed("return")
      assertResolvedMessage(state, "profile.final", "GOLD")
    end)
  end)
end

function T.tests.production_name_entry_resolves_blank_defaults_and_reenters_cleanly()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state, host)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")

      Assert.isTrue(state:view().nameInputEnabled)
      Assert.equal(host.textInputCalls[#host.textInputCalls], true)
      submitName(state)
      Assert.equal(state:view().phase, "name_confirm")
      Assert.equal(state:view().name, "Ethan")
      Assert.equal(host.textInputCalls[#host.textInputCalls], false)
      assertResolvedMessage(state, "profile.name_confirm.male", "Ethan")

      finishDialogueBoundary(state)
      state:keypressed("escape")
      Assert.equal(state:view().phase, "gender_question")
      enterGenderSelection(state)
      state:keypressed("right")
      state:keypressed("return")
      finishDialogueBoundary(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      Assert.equal(state:view().name, "")
      Assert.isTrue(state:view().nameInputEnabled)

      state:textinput("  ")
      Assert.equal(state:view().name, "  ")
      state:keypressed("backspace")
      Assert.equal(state:view().name, " ")
      submitName(state)
      Assert.equal(state:view().phase, "name_confirm")
      local expectedDefault = state:view().genderFocus == 0 and "Ethan" or "Lyra"
      Assert.equal(state:view().name, expectedDefault)
      Assert.equal(host.textInputCalls[#host.textInputCalls], false)
      assertResolvedMessage(
        state,
        state:view().genderFocus == 0 and "profile.name_confirm.male" or "profile.name_confirm.female",
        expectedDefault
      )
    end)
  end)
end

function T.tests.profile_visuals_keep_their_source_screen_geometry()
  forEachReadyVersion(function(versionId)
    for _, female in ipairs({ false, true }) do
      withProductionOak(versionId, function(state)
        reachFinalFullArtHold(state, female)
        local genderId = female and "female" or "male"
        local _, fullSource = assertSubjectUsesOwnSourceGeometry(state, genderId, 800, 600)
        local _, resizedSource = assertSubjectUsesOwnSourceGeometry(state, genderId, 390, 844)
        Assert.near(resizedSource.x, fullSource.x, 1e-6, "resizing must preserve the profile source X")
        Assert.near(resizedSource.y, fullSource.y, 1e-6, "resizing must preserve the profile source Y")

        state:tick(30)
        local shrinkId = female and "shrink_female" or "shrink_male"
        for frameIndex = 1, 4 do
          local view = assertSubjectUsesOwnSourceGeometry(state, shrinkId, 390, 844)
          Assert.equal(view.visualFrameIndex, frameIndex, "shrink frames must remain discrete and ordered")
          local canvas = view.layout.sourceCanvas
          Assert.equal(canvas.reference.width, state.manifest.sourceReference.width)
          Assert.equal(canvas.reference.height, state.manifest.sourceReference.height)
          if frameIndex < 4 then
            state:tick(9)
          end
        end
        assertSubjectUsesOwnSourceGeometry(state, shrinkId, 800, 600)
      end)
    end
  end)
end

function T.tests.profile_shrink_replacements_follow_nine_source_tick_boundaries()
  forEachReadyVersion(function(versionId)
    for _, female in ipairs({ false, true }) do
      withProductionOak(versionId, function(state)
        reachFinalFullArtHold(state, female)
        local shrinkId = female and "shrink_female" or "shrink_male"
        local frames = assert(state.manifest.widgets[shrinkId].frames)
        Assert.equal(#frames, 4, "the selected profile must have four replacement frames")
        for _, frame in ipairs(frames) do
          Assert.equal(frame.duration, 9, "replacement frames must use nine source ticks")
        end

        local holdStart = state:view().sourceFrames
        for _ = 1, 29 do
          state:update(1 / 30)
          Assert.equal(state:view().phase, "final_full_art_hold", "full art must hold for thirty source ticks")
        end
        state:update(1 / 30)
        local shrinkStart = state:view()
        Assert.equal(shrinkStart.sourceFrames - holdStart, 30)
        Assert.equal(shrinkStart.phase, "shrink_animation")
        Assert.equal(shrinkStart.primaryWidget, shrinkId)
        Assert.equal(shrinkStart.visualFrameIndex, 1)

        for frameIndex = 1, 3 do
          for _ = 1, 8 do
            state:update(1 / 30)
            Assert.equal(state:view().phase, "shrink_animation")
            Assert.equal(state:view().visualFrameIndex, frameIndex)
          end
          state:update(1 / 30)
          Assert.equal(state:view().phase, "shrink_animation")
          Assert.equal(state:view().visualFrameIndex, frameIndex + 1)
        end
        for _ = 1, 8 do
          state:update(1 / 30)
          Assert.equal(state:view().phase, "shrink_animation")
          Assert.equal(state:view().visualFrameIndex, 4)
        end
        state:update(1 / 30)
        local complete = state:view()
        Assert.equal(complete.phase, "complete")
        Assert.equal(complete.sourceFrames - shrinkStart.sourceFrames, 36)
        Assert.equal(#eventsNamed(state, "handoff"), 1)
      end)
    end
  end)
end

function T.tests.production_oak_reveal_uses_source_stage_boundaries()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    withProductionOak(versionId, function(state)
      advanceUntilMessage(state, "oak.world_inhabited")
      finishDialogueBoundary(state)

      local view = state:view()
      Assert.equal(view.phase, "ball_open_wait")
      Assert.equal(view.revealWidget, "ball_open")
      local firstBallFrame = view.revealFrameIndex

      advanceUntilPhase(state, "scene_flash")
      view = state:view()
      Assert.equal(view.revealWidget, "ball_open", "the ball must remain through the scene flash")
      Assert.equal(
        view.sceneBrightness,
        1,
        "the flash must begin at full scene brightness (phase=" .. tostring(view.phase) .. ")"
      )
      Assert.equal(#eventsNamed(state, "ball_flash"), 1)
      Assert.equal(view.revealFrameIndex, firstBallFrame, "the ball hold must use its source timing")

      local expectedBrightness = { 12 / 16, 8 / 16, 4 / 16, 0 }
      for _, brightness in ipairs(expectedBrightness) do
        state:tick(1)
        view = state:view()
        Assert.equal(view.sceneBrightness, brightness)
        if brightness > 0 then
          Assert.equal(view.revealWidget, "ball_open")
        end
      end
      Assert.equal(view.revealWidget, "marill_appear")
      Assert.equal(view.revealBrightness, 1)

      local appearanceFrames = assert(state.manifest.widgets.marill_appear.frames)
      local appearanceStartSourceFrame = view.sourceFrames
      local appearanceUnits = durationTotal(appearanceFrames)
      for _ = 1, 2000 do
        state:tick(1)
        view = state:view()
        if view.revealWidget == "marill" and view.revealBrightness == 0 then
          break
        end
      end
      Assert.equal(view.revealWidget, "marill")
      Assert.equal(view.revealBrightness, 0)
      Assert.equal(#eventsNamed(state, "marill_appears"), 1)
      Assert.equal(
        view.sourceFrames - appearanceStartSourceFrame,
        math.ceil(appearanceUnits / 2) + 16,
        "appearance animation and brightness fade must use their source clocks"
      )
    end)
  end)
end

function T.tests.production_oak_keeps_marill_visible_through_dialogue_and_hide()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    withProductionOak(versionId, function(state)
      advanceUntilMessage(state, "oak.world_inhabited")
      finishDialogueBoundary(state)
      state:tick(30)
      state:tick(4)

      advanceUntilMessage(state, "oak.live_alongside")
      local view = state:view()
      Assert.equal(view.revealWidget, "marill")
      Assert.equal(view.revealBrightness, 0)
      Assert.equal(view.revealOpacity, 1)

      finishDialogueBoundary(state)
      view = state:view()
      Assert.equal(view.revealWidget, "marill")
      Assert.equal(view.phase, "marill_hide")
      Assert.equal(view.revealOpacity, 15 / 16, "dialogue completion must start, not skip, the hide")
      Assert.equal(view.oakBgScrollX, -52)

      local expectedOpacity = {
        14 / 16,
        13 / 16,
        12 / 16,
        11 / 16,
        10 / 16,
        9 / 16,
        8 / 16,
        7 / 16,
        6 / 16,
        5 / 16,
        4 / 16,
        3 / 16,
        2 / 16,
        1 / 16,
        0,
      }
      for _, opacity in ipairs(expectedOpacity) do
        state:tick(1)
        view = state:view()
        if opacity > 0 then
          Assert.equal(view.revealWidget, "marill")
        end
        Assert.equal(view.revealOpacity, opacity)
      end
      Assert.isNil(view.revealWidget)
      Assert.equal(view.phase, "marill_hide_wait")
      Assert.equal(view.oakBgScrollX, -52)

      state:tick(30)
      view = state:view()
      Assert.equal(view.phase, "oak_slide_left")
      Assert.equal(view.oakBgScrollX, -52)
    end)
  end)
end

-- The intentional fastest text speed is a protected product decision (not a
-- reverted source regression): it must survive a full production Oak flow,
-- including a default-name resolution, into the FieldRuntime that Oak hands
-- off to.
function T.tests.default_name_and_fastest_text_speed_survive_the_full_oak_handoff()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state, _, completion)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      Assert.equal(state:view().phase, "gender_confirm")
      state:keypressed("return")

      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      Assert.equal(state:view().name, "")

      submitName(state)
      Assert.equal(state:view().phase, "name_confirm")
      Assert.equal(state:view().name, "Ethan")

      finishDialogueBoundary(state)
      state:keypressed("return")
      Assert.equal(state:view().phase, "final_dialogue")

      finishDialogueBoundary(state)
      state:keypressed("return")

      advanceUntilPhase(state, "complete")
      Assert.equal(#completion, 1, "Oak completion must notify its owning application boundary")
      Assert.equal(completion[1].playerData.profile.name, "Ethan")
      Assert.equal(
        completion[1].options.textSpeed,
        "fastest",
        "the intentional fastest text speed must reach the field runtime unchanged"
      )
    end)
  end)
end

function T.tests.name_confirmation_keeps_question_and_vertical_navigation_through_resize()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state)
      reachNameConfirmation(state)
      local view = state:view()
      Assert.equal(view.phase, "name_confirm")
      Assert.deepEqual(view.confirmationChoice, { kind = "name", selected = 0 })
      Assert.isFalse(state.dialogueController:isModal(), "real dialogue must be closed while choice is active")
      Assert.notNil(view.layout.dialogue, "dialogue must remain reserved after close")
      Assert.notNil(view.dialoguePresentation, "presentation must persist after close")
      local oakRegion = assert(view.layout.oakRegion)
      local choiceRegion = assert(view.layout.selectorRegion)
      Assert.isTrue(oakRegion.x + oakRegion.width <= choiceRegion.x, "Oak must stay left of choices")
      local yes = assert(view.layout.confirmationButtons[0])
      local no = assert(view.layout.confirmationButtons[1])
      Assert.equal(yes.scale, no.scale)
      Assert.equal(yes.rect.x, no.rect.x)
      Assert.isTrue(yes.rect.y + yes.rect.height <= no.rect.y)
      Assert.near((no.rect.y - (yes.rect.y + yes.rect.height)) / yes.scale, 8, 1e-6)
      Assert.isTrue(
        yes.rect.y >= oakRegion.y and yes.rect.y + yes.rect.height <= oakRegion.y + oakRegion.height
          or yes.rect.x >= choiceRegion.x
      )
      state:keypressed("left")
      Assert.equal(state:view().confirmationChoice.selected, 0, "left must be no-op for name confirmation")
      state:keypressed("right")
      Assert.equal(state:view().confirmationChoice.selected, 0, "right must be no-op for name confirmation")
      state:keypressed("up")
      Assert.equal(state:view().confirmationChoice.selected, 0)
      state:keypressed("down")
      Assert.equal(state:view().confirmationChoice.selected, 1)
      state:keypressed("down")
      Assert.equal(state:view().confirmationChoice.selected, 1)
      state:keypressed("up")
      Assert.equal(state:view().confirmationChoice.selected, 0)
      for _, size in ipairs({ { 390, 844 }, { 640, 480 }, { 800, 600 } }) do
        state:resize(size[1], size[2])
        local resized = state:view()
        Assert.equal(resized.phase, "name_confirm")
        Assert.deepEqual(resized.confirmationChoice, { kind = "name", selected = 0 })
        Assert.isFalse(state.dialogueController:isModal())
        Assert.notNil(resized.layout.dialogue)
        Assert.notNil(resized.dialoguePresentation)
        local rOak = assert(resized.layout.oakRegion)
        local rChoice = assert(resized.layout.selectorRegion)
        Assert.isTrue(rOak.x + rOak.width <= rChoice.x)
        local rYes = assert(resized.layout.confirmationButtons[0])
        local rNo = assert(resized.layout.confirmationButtons[1])
        Assert.equal(rYes.rect.x, rNo.rect.x)
        Assert.isTrue(rYes.rect.y + rYes.rect.height <= rNo.rect.y)
        Assert.near((rNo.rect.y - (rYes.rect.y + rYes.rect.height)) / rYes.scale, 8, 1e-6)
        state:draw()
      end
    end)
  end)
end

function T.tests.affirmative_name_flow_keeps_oak_continuous_from_gender_endpoint_through_final_dialogue()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state)
      advanceUntilMessage(state, "profile.gender_question")
      enterGenderSelection(state)
      state:resize(640, 480)
      local genderView = state:view()
      Assert.equal(genderView.phase, "gender_select")
      Assert.equal(genderView.genderCompositionProgress, 1)
      local genderSubject = assert(genderView.layout.subject)
      Assert.isTrue(genderSubject.x >= 0 and genderSubject.y >= 0)

      state:keypressed("return")
      finishDialogueBoundary(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      state:keypressed("left")
      state:keypressed("return")
      local startView = state:view()
      Assert.equal(startView.phase, "name_composition_transition")
      Assert.equal(startView.genderCompositionProgress, 1)
      Assert.equal(startView.nameCompositionProgress, 0)
      local startSubject = assert(startView.layout.subject)
      Assert.near(startSubject.x, genderSubject.x, 1e-4)
      Assert.near(startSubject.y, genderSubject.y, 1e-4)
      Assert.near(startSubject.scale, genderSubject.scale, 1e-6)
      Assert.near(startSubject.width, genderSubject.width, 1e-4)
      Assert.near(startSubject.height, genderSubject.height, 1e-4)

      for _ = 1, 13 do
        state:tick(1)
      end
      local midView = state:view()
      Assert.equal(midView.nameCompositionProgress, 0.5)
      local midSubject = assert(midView.layout.subject)
      Assert.isTrue(midSubject.width > 0 and midSubject.height > 0)

      state:resize(390, 844)
      local resized = state:view()
      Assert.equal(resized.nameCompositionProgress, 0.5)
      Assert.equal(resized.genderCompositionProgress, 1)
      local resizedSubject = assert(resized.layout.subject)
      Assert.isTrue(resizedSubject.x >= 0 and resizedSubject.y >= 0)
      Assert.isTrue(resizedSubject.x + resizedSubject.width <= 390 + 1e-6)
      Assert.isTrue(resizedSubject.y + resizedSubject.height <= 844 + 1e-6)

      for _ = 1, 13 do
        state:tick(1)
      end
      local finished = state:view()
      Assert.equal(finished.phase, "name_confirm")
      Assert.equal(finished.nameCompositionProgress, 1)
      Assert.equal(finished.genderCompositionProgress, 1)
      local finishedSubject = assert(finished.layout.subject)

      finishDialogueBoundary(state)
      local stable = state:view()
      Assert.equal(stable.phase, "name_confirm")
      Assert.deepEqual(stable.confirmationChoice, { kind = "name", selected = 0 })
      local stableSubject = assert(stable.layout.subject)
      Assert.near(stableSubject.x, finishedSubject.x, 1e-4)
      Assert.near(stableSubject.y, finishedSubject.y, 1e-4)
      Assert.near(stableSubject.scale, finishedSubject.scale, 1e-6)
      Assert.near(stableSubject.width, finishedSubject.width, 1e-4)
      Assert.near(stableSubject.height, finishedSubject.height, 1e-4)

      local stableOakRegion = assert(stable.layout.oakRegion)
      state:keypressed("return")
      local finalView = state:view()
      Assert.equal(finalView.phase, "final_dialogue")
      Assert.equal(finalView.messageKey, "profile.final")
      local finalSubject = assert(finalView.layout.subject)
      Assert.near(finalSubject.x, stableSubject.x, 1e-4)
      Assert.near(finalSubject.y, stableSubject.y, 1e-4)
      Assert.near(finalSubject.scale, stableSubject.scale, 1e-6)
      Assert.near(finalSubject.width, stableSubject.width, 1e-4)
      Assert.near(finalSubject.height, stableSubject.height, 1e-4)
      Assert.deepEqual(finalView.layout.oakRegion, stableOakRegion)
      Assert.isTrue(finalView.layout.selectorRegion.x >= stableOakRegion.x + stableOakRegion.width - 1e-4)
    end)
  end)
end

function T.tests.rejected_name_holds_left_placement_then_returns_through_midpoint_to_gender_selection()
  forEachReadyVersion(function(versionId)
    withProductionOak(versionId, function(state)
      reachNameConfirmation(state)
      local nameView = state:view()
      Assert.equal(nameView.phase, "name_confirm")
      Assert.equal(nameView.genderCompositionProgress, 1)
      Assert.equal(nameView.nameCompositionProgress, 1)
      local nameSubject = assert(nameView.layout.subject)
      local nameOakRegion = assert(nameView.layout.oakRegion)

      state:keypressed("down")
      state:keypressed("return")
      local rejected = state:view()
      Assert.equal(rejected.phase, "gender_question")
      Assert.equal(rejected.messageKey, "profile.gender_question")
      Assert.equal(rejected.nameCompositionProgress, 1)
      Assert.equal(rejected.genderCompositionProgress, 1)
      local rejectedSubject = assert(rejected.layout.subject)
      Assert.near(rejectedSubject.x, nameSubject.x, 1e-4)
      Assert.near(rejectedSubject.y, nameSubject.y, 1e-4)
      Assert.near(rejectedSubject.scale, nameSubject.scale, 1e-6)
      Assert.deepEqual(rejected.layout.oakRegion, nameOakRegion)

      finishDialogueBoundary(state)
      local transitionStart = state:view()
      Assert.equal(transitionStart.phase, "name_composition_return")
      Assert.equal(transitionStart.nameCompositionProgress, 1)
      Assert.equal(transitionStart.genderCompositionProgress, 1)
      local startSubject = assert(transitionStart.layout.subject)
      Assert.near(startSubject.x, nameSubject.x, 1e-4)
      Assert.near(startSubject.y, nameSubject.y, 1e-4)
      Assert.near(startSubject.scale, nameSubject.scale, 1e-6)

      for _ = 1, 13 do
        state:tick(1)
      end
      local midView = state:view()
      Assert.equal(midView.nameCompositionProgress, 0.5)
      local midSubject = assert(midView.layout.subject)

      for _ = 1, 13 do
        state:tick(1)
      end
      local finished = state:view()
      Assert.equal(finished.phase, "gender_select")
      Assert.equal(finished.nameCompositionProgress, 0)
      Assert.equal(finished.genderCompositionProgress, 1)
      local genderSubject = assert(finished.layout.subject)

      local expectedMidX = (nameSubject.x + genderSubject.x) / 2
      local expectedMidY = (nameSubject.y + genderSubject.y) / 2
      local expectedMidScale = (nameSubject.scale + genderSubject.scale) / 2
      local expectedMidWidth = (nameSubject.width + genderSubject.width) / 2
      local expectedMidHeight = (nameSubject.height + genderSubject.height) / 2
      Assert.near(midSubject.x, expectedMidX, 1e-4)
      Assert.near(midSubject.y, expectedMidY, 1e-4)
      Assert.near(midSubject.scale, expectedMidScale, 1e-6)
      Assert.near(midSubject.width, expectedMidWidth, 1e-4)
      Assert.near(midSubject.height, expectedMidHeight, 1e-4)

      local stable = state:view()
      Assert.equal(stable.phase, "gender_select")
      local stableSubject = assert(stable.layout.subject)
      Assert.near(stableSubject.x, genderSubject.x, 1e-4)
      Assert.near(stableSubject.y, genderSubject.y, 1e-4)
      Assert.near(stableSubject.scale, genderSubject.scale, 1e-6)
    end)
  end)
end

return T
