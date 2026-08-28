-- Product New Game acceptance: the real Main Menu and App compose Oak from
-- the selected generated cache without a test Oak factory.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FakeCache = require("tests.support.FakeCache")
local App = require("game.src.game.App")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local GameSaveStore = require("libs.engine.src.GameSaveStore")
local OakIntroState = require("game.src.game.OakIntroState")
local SaveFs = require("libs.storage.src.SaveFs")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "oak", "product", "composition" },
  },
  tests = {},
}

local hostSeams

local function withProductionOak(versionId, fn)
  local original = {
    opts = App.opts,
    state = App.state,
    saveStore = App.saveStore,
    versionId = App.versionId,
  }
  local store = GameSaveStore.new(SaveFs.global(FakeCache.new()))
  local host = hostSeams()
  App.opts = {
    saveStore = store,
    oakIntroHost = host,
    test = false,
    actors = false,
    dev = false,
  }
  App.saveStore = store
  App.state = nil
  App.versionId = nil

  local ok, err = xpcall(function()
    App._bootMainMenu({ versionId })
    App.keypressed("return")
    Assert.equal(getmetatable(App.state).__index, OakIntroState)
    fn(App.state, host)
  end, debug.traceback)

  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  App.saveStore = original.saveStore
  App.versionId = original.versionId
  if not ok then
    error(err, 0)
  end
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
  if state:view().phase == "gender_composition_transition" then
    state:tick(26)
  end
  Assert.equal(state:view().phase, "gender_select")
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
  local original = {
    opts = App.opts,
    state = App.state,
    saveStore = App.saveStore,
    versionId = App.versionId,
  }
  local store = GameSaveStore.new(SaveFs.global(FakeCache.new()))
  ---@type AppOptions
  App.opts = {
    saveStore = store,
    oakIntroHost = hostSeams(),
    test = false,
    actors = false,
    dev = false,
  }
  App.saveStore = store
  App.state = nil
  App.versionId = nil

  local ok, err = xpcall(function()
    App._bootMainMenu({ "heartgold" })
    App.keypressed("return")
    Assert.equal(getmetatable(App.state).__index, OakIntroState)
    Assert.equal(App.state.controller:candidate().saveId, "save-00000001")
  end, debug.traceback)

  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  App.saveStore = original.saveStore
  App.versionId = original.versionId
  if not ok then
    error(err, 0)
  end
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
        for tick = 1, 29 do
          state:tick(1)
          Assert.equal(state:view().phase, "final_full_art_hold", "full art must hold for thirty source ticks")
        end
        state:tick(1)
        local shrinkStart = state:view()
        Assert.equal(shrinkStart.sourceFrames - holdStart, 30)
        Assert.equal(shrinkStart.phase, "shrink_animation")
        Assert.equal(shrinkStart.primaryWidget, shrinkId)
        Assert.equal(shrinkStart.visualFrameIndex, 1)

        for frameIndex = 1, 3 do
          for _ = 1, 8 do
            state:tick(1)
            Assert.equal(state:view().phase, "shrink_animation")
            Assert.equal(state:view().visualFrameIndex, frameIndex)
          end
          state:tick(1)
          Assert.equal(state:view().phase, "shrink_animation")
          Assert.equal(state:view().visualFrameIndex, frameIndex + 1)
        end
        for _ = 1, 8 do
          state:tick(1)
          Assert.equal(state:view().phase, "shrink_animation")
          Assert.equal(state:view().visualFrameIndex, 4)
        end
        state:tick(1)
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
      local firstAppearanceFrame = view.revealFrameIndex
      local firstDuration = appearanceFrames[firstAppearanceFrame].duration
      if firstDuration > 1 then
        state:tick(firstDuration - 1)
        Assert.equal(state:view().revealFrameIndex, firstAppearanceFrame)
      end

      local brightnessTrace = {}
      for _ = 1, 2000 do
        state:tick(1)
        view = state:view()
        brightnessTrace[#brightnessTrace + 1] = view.revealBrightness
        if view.revealWidget == "marill" and view.revealBrightness == 0 then
          break
        end
      end
      Assert.equal(view.revealWidget, "marill")
      Assert.equal(view.revealBrightness, 0)
      Assert.equal(#eventsNamed(state, "marill_appears"), 1)
      Assert.isTrue(#brightnessTrace >= durationTotal(appearanceFrames) - firstDuration + 1 + 16)
      Assert.equal(brightnessTrace[#brightnessTrace], 0)
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
    withProductionOak(versionId, function(state)
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
      Assert.equal(getmetatable(App.state).__index ~= OakIntroState, true, "Oak completion must hand off to the field")
      Assert.equal(App.state.runtime.playerData.profile.name, "Ethan")
      Assert.equal(
        App.state.runtime.playerData.options.textSpeed,
        "fastest",
        "the intentional fastest text speed must reach the field runtime unchanged"
      )
    end)
  end)
end

return T
