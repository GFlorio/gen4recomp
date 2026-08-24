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
    App._bootMainMenu({ versionId })
    App.keypressed("return")
    Assert.equal(getmetatable(App.state).__index, OakIntroState)
    fn(App.state)
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
    textInputHost = { setTextInput = function() end },
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
      finishDialogueBoundary(state)
      state:keypressed("return")
      Assert.equal(state:view().messageKey, "profile.gender_confirm.male")

      finishDialogueBoundary(state)
      local view = state:view()
      Assert.equal(view.phase, "gender_confirm")
      Assert.equal(view.confirmationChoice.selected, 0)

      state:keypressed("down")
      state:keypressed("escape")
      Assert.equal(state:view().phase, "gender_question")

      finishDialogueBoundary(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      Assert.equal(state:view().phase, "gender_confirm")
      state:keypressed("return")
      Assert.equal(state:view().phase, "name_prompt")

      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      state:keypressed("return")
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
      finishDialogueBoundary(state)
      state:keypressed("right")
      state:keypressed("return")
      finishDialogueBoundary(state)
      Assert.equal(state:view().phase, "gender_confirm")
      state:keypressed("return")

      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      state:keypressed("return")
      assertResolvedMessage(state, "profile.name_confirm.female", "GOLD")
      finishDialogueBoundary(state)
      state:keypressed("escape")

      finishDialogueBoundary(state)
      state:keypressed("left")
      state:keypressed("return")
      finishDialogueBoundary(state)
      state:keypressed("return")
      finishDialogueBoundary(state)
      advanceUntilPhase(state, "name_edit")
      state:textinput("GOLD")
      state:keypressed("return")
      assertResolvedMessage(state, "profile.name_confirm.male", "GOLD")
      finishDialogueBoundary(state)
      state:keypressed("return")
      assertResolvedMessage(state, "profile.final", "GOLD")
    end)
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
      Assert.equal(view.oakSlideOffset, -52)

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
      Assert.equal(view.oakSlideOffset, -52)

      state:tick(30)
      view = state:view()
      Assert.equal(view.phase, "oak_slide_left")
      Assert.equal(view.oakSlideOffset, -52)
    end)
  end)
end

return T
