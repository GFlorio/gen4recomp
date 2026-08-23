-- Product New Game acceptance: the real Main Menu and App compose Oak from
-- the selected generated cache without a test Oak factory.

local Assert = require("tests.support.Assert")
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
  local message = assert(state:view().dialogue and state:view().dialogue.message)
  Assert.equal(state:view().messageKey, messageKey)
  Assert.isFalse(message.hadUnresolvedSubstitutions)
  Assert.isTrue(message.text:find(playerName, 1, true) ~= nil, "Oak message must contain the current player name")
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

  local graphics = {
    newQuad = function()
      return {}
    end,
  }
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
      state:keypressed("return")
      state:keypressed("return")
      Assert.equal(state:view().messageKey, "profile.gender_confirm.male")

      finishDialogueBoundary(state)
      local view = state:view()
      Assert.equal(view.phase, "gender_confirm")
      Assert.equal(view.confirmationChoice.selected, 0)

      state:keypressed("down")
      state:keypressed("escape")
      Assert.equal(state:view().phase, "gender_question")

      state:keypressed("return")
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
      state:keypressed("return")
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

      state:keypressed("return")
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

return T
