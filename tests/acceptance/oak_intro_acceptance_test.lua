-- Production-composed Oak/profile acceptance. The Main Menu and App route are
-- real; generated intro resources, local time, audio output, and rendering are
-- deterministic host seams so the flow stops before GPU work.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local FieldState = require("game.src.game.FieldState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local FieldEventState = require("libs.engine.src.FieldEventState")
local OakIntroController = require("libs.engine.src.OakIntroController")

local T = {
  metadata = {
    tags = { "oak", "profile", "routing", "input", "audio" },
  },
  tests = {},
}

local READY_VERSION = "heartgold"
local VIRTUAL_GLYPHS = { "A", "B", "C", "D", "E", "F", "G", "O", "L", "é" }
local CHARMAP = { A = 1, B = 2, C = 3, D = 4, E = 5, F = 6, G = 7, O = 8, L = 9, ["é"] = 10 }
local PLAYER_DATA_CONTEXT = { charmap = CHARMAP, frameIndexes = { [0] = true } }

local MESSAGES = {
  ["greeting.midnight"] = "generated.greeting.midnight",
  ["greeting.morning"] = "generated.greeting.morning",
  ["greeting.day"] = "generated.greeting.day",
  ["greeting.evening"] = "generated.greeting.evening",
  ["greeting.night"] = "generated.greeting.night",
  ["profile.ask"] = "generated.profile.ask",
  ["profile.gender_question"] = "generated.profile.gender_question",
  ["profile.gender_select"] = "generated.profile.gender_select",
  ["profile.gender_confirm"] = "generated.profile.gender_confirm",
  ["profile.name_confirm"] = "generated.profile.name_confirm",
  ["profile.final"] = "generated.profile.final",
}

local function recordingAudio()
  local audio = { events = {}, fadeActive = false, soundFrames = 0 }

  local function record(name, value)
    audio.events[#audio.events + 1] = { name = name, value = value }
  end

  function audio:playMusic(id)
    record("music", id)
  end

  function audio:stopMusic()
    record("stop_music")
  end

  function audio:fadeMusicOut(spec)
    record("fade_out", spec)
    self.fadeActive = true
  end

  function audio:play(id)
    record("effect", id)
  end

  function audio:playCry(species, form)
    record("cry", { species = species, form = form })
  end

  function audio:updateSoundFrame()
    self.soundFrames = self.soundFrames + 1
  end

  function audio:isMusicFadeActive()
    return self.fadeActive
  end

  return audio
end

local function mutableClock(hour, minute)
  local clock = { hour = hour, minute = minute, calls = 0 }
  function clock:nowLocal()
    self.calls = self.calls + 1
    return {
      year = 2026,
      month = 8,
      day = 22,
      hour = self.hour,
      minute = self.minute,
      second = 0,
    }
  end
  return clock
end

local function fakeRenderer()
  return {
    disposed = 0,
    draw = function() end,
    dispose = function(self)
      self.disposed = self.disposed + 1
    end,
  }
end

local function fakeStore()
  local store = { listCalls = 0, reserveCalls = 0, publishCalls = 0 }
  function store:list()
    self.listCalls = self.listCalls + 1
    return {}
  end
  function store:reserve(versionId)
    Assert.equal(versionId, READY_VERSION)
    self.reserveCalls = self.reserveCalls + 1
    return 27
  end
  return store
end

local function eventKinds(controller)
  local result = {}
  for _, event in ipairs(controller:view().events) do
    result[#result + 1] = event.kind
  end
  return result
end

local function eventValues(controller, kind)
  local result = {}
  for _, event in ipairs(controller:view().events) do
    if event.kind == kind then
      result[#result + 1] = event.value
    end
  end
  return result
end

local function startFlow(options, fn)
  options = options or {}
  local original = {
    opts = App.opts,
    state = App.state,
    saveStore = App.saveStore,
    versionId = App.versionId,
    menuResult = App.menuResult,
    fieldNew = FieldState.new,
  }
  if App.state then
    App.setState(nil)
  end

  local store = fakeStore()
  local clock = options.clock or mutableClock(12, 0)
  local audio = options.audio or recordingAudio()
  local inputHost = { calls = {} }
  function inputHost:setTextInput(enabled)
    self.calls[#self.calls + 1] = enabled
  end
  local renderer = fakeRenderer()
  local controller
  local fieldCalls = {}

  ---@type AppOptions
  App.opts = {
    test = false,
    actors = false,
    dev = false,
    saveStore = store,
    oakIntroOptionsFactory = function(factoryOptions)
      Assert.equal(factoryOptions.versionId, READY_VERSION)
      controller = OakIntroController.new({
        candidate = factoryOptions.candidate,
        clock = clock,
        audio = audio,
        messages = MESSAGES,
        virtualGlyphs = VIRTUAL_GLYPHS,
        playerDataContext = PLAYER_DATA_CONTEXT,
        randomU32 = function()
          return 0x12345678
        end,
      })
      return {
        controller = controller,
        manifest = {},
        renderer = renderer,
        textInputHost = inputHost,
        glyphs = VIRTUAL_GLYPHS,
        width = options.width or 960,
        height = options.height or 540,
      }
    end,
  }
  App.saveStore = store
  App.versionId = nil
  App.menuResult = nil
  ---@diagnostic disable-next-line: duplicate-set-field
  FieldState.new = function(game, fieldOptions)
    fieldCalls[#fieldCalls + 1] = { game = game, options = fieldOptions }
    return { kind = "field" }
  end

  local ok, err = xpcall(function()
    App._bootMainMenu({ READY_VERSION })
    Assert.equal(App.state:view().kind, "main_menu")
    App.keypressed("return")
    Assert.notNil(controller, "New Game must enter the real Oak controller boundary")
    Assert.equal(App.state.controller, controller)
    fn({
      audio = audio,
      clock = clock,
      controller = controller,
      fieldCalls = fieldCalls,
      inputHost = inputHost,
      renderer = renderer,
      store = store,
    })
  end, debug.traceback)

  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  App.saveStore = original.saveStore
  App.versionId = original.versionId
  App.menuResult = original.menuResult
  FieldState.new = original.fieldNew
  if not ok then
    error(err, 0)
  end
end

local function advance(frames)
  Assert.isTrue(App.state ~= nil, "Oak flow ended before the requested source frames")
  App.state:tick(frames)
end

local function confirm()
  App.keypressed("return")
end

local function reachGenderSelect(audio)
  advance(40)
  confirm()
  -- These scenarios exercise profile input after the fade; the dedicated
  -- audio scenario controls this host completion explicitly.
  audio.fadeActive = false
  advance(6 + 30 + 30 + 40)
  confirm()
  confirm()
  Assert.equal(App.state:view().phase, "gender_select")
end

local function reachNameEditor(audio)
  reachGenderSelect(audio)
  confirm()
  confirm()
  confirm()
  Assert.equal(App.state:view().phase, "name_edit")
end

function T.tests.new_game_routes_through_the_core_oak_sequence()
  startFlow({}, function(context)
    Assert.equal(context.clock.calls, 0)
    Assert.deepEqual(context.audio.events, { { name = "music", value = "SEQ_GS_STARTING" } })

    advance(40)
    Assert.equal(context.clock.calls, 1)
    Assert.equal(context.controller:view().message, MESSAGES["greeting.day"])
    confirm()
    context.audio.fadeActive = false
    advance(6 + 30 + 30 + 40)

    Assert.equal(context.controller:view().phase, "profile")
    Assert.deepEqual(eventKinds(context.controller), {
      "started",
      "message",
      "oak_revealed",
      "marill_appears",
      "message",
    })
    Assert.deepEqual(eventValues(context.controller, "message"), { "greeting.day", "profile.ask" })

    confirm()
    confirm()
    confirm()
    confirm()
    App.textinput("GOLD")
    confirm()
    confirm()
    confirm()
    advance(30)
    Assert.equal(#context.fieldCalls, 1)
    Assert.equal(context.fieldCalls[1].game.playerData.profile.name, "GOLD")
    Assert.equal(App.state.kind, "field")
  end)
end

function T.tests.greeting_boundaries_are_sampled_at_the_queue_point()
  local cases = {
    { 3, 59, "greeting.midnight" },
    { 4, 0, "greeting.morning" },
    { 10, 59, "greeting.morning" },
    { 11, 0, "greeting.day" },
    { 15, 59, "greeting.day" },
    { 16, 0, "greeting.evening" },
    { 18, 59, "greeting.evening" },
    { 19, 0, "greeting.night" },
    { 23, 59, "greeting.night" },
  }

  for _, case in ipairs(cases) do
    startFlow({ clock = mutableClock(case[1], case[2]) }, function(context)
      advance(39)
      context.clock.hour, context.clock.minute = case[1], case[2]
      advance(1)
      Assert.equal(context.controller:view().message, MESSAGES[case[3]])
      Assert.equal(context.clock.calls, 1)
    end)
  end

  startFlow({ clock = mutableClock(3, 59) }, function(context)
    advance(39)
    context.clock.hour, context.clock.minute = 4, 0
    advance(1)
    Assert.equal(context.controller:view().message, MESSAGES["greeting.morning"])
  end)
end

function T.tests.gender_and_name_rejections_follow_the_source_backtrack()
  startFlow({}, function(context)
    reachGenderSelect(context.audio)
    App.gamepadpressed({}, "dpright")
    App.gamepadpressed({}, "a")
    Assert.equal(App.state:view().phase, "gender_confirm")
    App.gamepadpressed({}, "b")
    Assert.equal(App.state:view().phase, "gender_question")
    confirm()
    Assert.equal(App.state:view().phase, "gender_select")
    Assert.equal(App.state:view().genderFocus, 1)

    confirm()
    confirm()
    confirm()
    App.textinput("GOLD")
    confirm()
    Assert.equal(App.state:view().phase, "name_confirm")
    App.keypressed("escape")
    Assert.equal(App.state:view().phase, "gender_question")
    confirm()
    confirm()
    confirm()
    Assert.equal(App.state:view().phase, "name_edit")
    Assert.equal(App.state:view().name, "")

    Assert.isNil(context.controller:candidate().playerData)
  end)
end

function T.tests.audio_and_fixed_source_timing_are_ordered_and_cry_independent()
  startFlow({ audio = recordingAudio() }, function(context)
    advance(40)
    confirm()
    Assert.equal(context.controller:view().phase, "fade_wait")
    Assert.equal(context.audio.events[2].name, "fade_out")
    Assert.equal(context.audio.events[2].value.durationTicks, 6)

    advance(6)
    Assert.equal(context.controller:view().phase, "fade_wait")
    for _, event in ipairs(context.audio.events) do
      Assert.isFalse(event.name == "music" and event.value == "SEQ_GS_STARTING2")
    end
    context.audio.fadeActive = false
    advance(1)
    Assert.equal(context.controller:view().phase, "oak_reveal_wait")
    Assert.deepEqual({
      context.audio.events[3].name,
      context.audio.events[3].value,
      context.audio.events[4].name,
      context.audio.events[4].value,
    }, { "stop_music", nil, "music", "SEQ_GS_STARTING2" })

    advance(30)
    Assert.equal(context.controller:view().phase, "marill_appearance_wait")
    advance(30)
    Assert.equal(context.controller:view().phase, "marill_cry_wait")
    Assert.deepEqual(context.audio.events[#context.audio.events - 1], { name = "effect", value = "SEQ_SE_DP_BOWA2" })
    Assert.deepEqual(context.audio.events[#context.audio.events], { name = "cry", value = { species = 184, form = 0 } })
    advance(39)
    Assert.equal(context.controller:view().phase, "marill_cry_wait")
    advance(1)
    Assert.equal(context.controller:view().phase, "profile")
  end)
end

function T.tests.final_confirmation_hands_off_a_valid_unpublished_game()
  startFlow({}, function(context)
    reachNameEditor(context.audio)
    App.textinput("GOLD")
    confirm()
    Assert.equal(App.state:view().phase, "name_confirm")
    confirm()
    Assert.equal(App.state:view().phase, "final_dialogue")
    confirm()
    Assert.equal(App.state:view().phase, "shrink_wait")
    Assert.isNil(context.controller:candidate().playerData)
    advance(29)
    Assert.equal(App.state:view().phase, "shrink_wait")
    advance(1)

    Assert.equal(App.state.kind, "field")
    Assert.equal(#context.fieldCalls, 1)
    local result = context.fieldCalls[1].game
    Assert.equal(result.saveId, 27)
    Assert.equal(result.playerData.profile.name, "GOLD")
    Assert.equal(result.playerData.profile.gender, 0)
    Assert.equal(result.playerData.profile.trainerId, 0x12345678)
    Assert.equal(result.playerData.profile.money, 3000)
    Assert.equal(result.location.mapSymbol, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
    Assert.equal(context.store.reserveCalls, 1)
    Assert.equal(context.store.publishCalls, 0)
    Assert.equal(#context.store:list(), 0)
  end)
end

function T.tests.resize_and_all_input_modalities_share_oak_geometry_and_buffer()
  startFlow({ width = 960, height = 540 }, function(context)
    reachGenderSelect(context.audio)
    App.gamepadpressed({}, "dpright")
    App.gamepadpressed({}, "a")
    Assert.equal(App.state:view().phase, "gender_confirm")
    App.keypressed("escape")
    confirm()
    Assert.equal(App.state:view().genderFocus, 1)
    App.resize(420, 800)
    Assert.equal(App.state:view().layout.viewport.width, 420)
    Assert.equal(App.state:view().genderFocus, 1)
    local card = App.state:view().layout.cards[1]
    App.touchpressed("finger-1", card.x + 1, card.y + 1)
    Assert.equal(App.state:view().phase, "gender_confirm")

    confirm()
    confirm()
    Assert.equal(App.state:view().phase, "name_edit")
    App.textinput("A")
    local layout = App.state:view().layout
    local key = layout.nameGrid["é"].rect
    App.mousepressed(key.x + 1, key.y + 1, 1)
    Assert.equal(App.state:view().name, "Aé")
    App.keypressed("backspace")
    Assert.equal(App.state:view().name, "A")
    App.gamepadpressed({}, "a")
    Assert.equal(App.state:view().name, "AA")
    Assert.deepEqual(context.inputHost.calls, { false, true })
    Assert.equal(context.renderer.disposed, 0)
  end)
end

return T
