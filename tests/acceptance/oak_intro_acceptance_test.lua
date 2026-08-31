-- Production-composed Oak/profile acceptance. The Main Menu and App route are
-- real; generated intro resources, local time, audio output, and rendering are
-- deterministic host seams so the flow stops before GPU work.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local FieldState = require("game.hgss.src.field.FieldState")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "oak", "profile", "routing", "input", "audio" },
  },
  tests = {},
}

local VIRTUAL_GLYPHS = { "A", "B", "C", "D", "E", "F", "G", "O", "L", "é" }
local CHARMAP = { A = 1, B = 2, C = 3, D = 4, E = 5, F = 6, G = 7, O = 8, L = 9, ["é"] = 10 }
local PLAYER_DATA_CONTEXT = { charmap = CHARMAP, frameIndexes = { [0] = true } }

local function animation(duration, count)
  local frames = {}
  for index = 1, count do
    frames[index] = { duration = duration }
  end
  return { frames = frames }
end

local INTRO_ASSETS = {
  marill = { frames = { { duration = 1 } } },
  marill_appear = { frames = { { duration = 1 } } },
  ball_open = { frames = { { duration = 1 } } },
  male = animation(1, 1),
  female = animation(1, 1),
  shrink_male = animation(9, 4),
  shrink_female = animation(9, 4),
}

local function profileWidget(width, height, x, y)
  return {
    width = width,
    height = height,
    anchor = { x = width / 2, y = height },
    sourceBounds = { x = x, y = y, width = width, height = height },
  }
end

local INTRO_MANIFEST = {
  sourceReference = { width = 256, height = 192 },
  background = { width = 1, height = 192, sampling = "linear" },
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
    ball_open = {
      width = 40,
      height = 30,
      anchor = { x = 20, y = 30 },
      sourceBounds = { x = 140, y = 50, width = 40, height = 30 },
      sourceCenter = { x = 160, y = 80 },
    },
    marill_appear = {
      width = 40,
      height = 30,
      anchor = { x = 20, y = 30 },
      sourceBounds = { x = 140, y = 50, width = 40, height = 30 },
      sourceCenter = { x = 160, y = 80 },
    },
    marill = {
      width = 40,
      height = 30,
      anchor = { x = 20, y = 30 },
      sourceBounds = { x = 140, y = 50, width = 40, height = 30 },
      sourceCenter = { x = 160, y = 80 },
    },
    male = profileWidget(96, 120, 36, 24),
    female = profileWidget(88, 116, 48, 28),
    shrink_male = profileWidget(44, 68, 142, 70),
    shrink_female = profileWidget(40, 64, 150, 72),
  },
}

local MESSAGES = {
  ["greeting.midnight"] = "generated.greeting.midnight",
  ["greeting.morning"] = "generated.greeting.morning",
  ["greeting.day"] = "generated.greeting.day",
  ["greeting.evening"] = "generated.greeting.evening",
  ["greeting.night"] = "generated.greeting.night",
  ["oak.welcome"] = "generated.oak.welcome",
  ["oak.world_inhabited"] = "generated.oak.world_inhabited",
  ["oak.live_alongside"] = "generated.oak.live_alongside",
  ["oak.tell_about_yourself"] = "generated.oak.tell_about_yourself",
  ["profile.gender_question"] = "generated.profile.gender_question",
  ["profile.gender_confirm.male"] = "generated.profile.gender_confirm.male",
  ["profile.gender_confirm.female"] = "generated.profile.gender_confirm.female",
  ["profile.name_prompt"] = "generated.profile.name_prompt",
  ["profile.name_confirm.male"] = "generated.profile.name_confirm.male",
  ["profile.name_confirm.female"] = "generated.profile.name_confirm.female",
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
  function store:reserve()
    self.reserveCalls = self.reserveCalls + 1
    return "save-00000027"
  end
  return store
end

local function startFlow(options, fn)
  options = options or {}
  local readyVersion = AcceptanceHarness.defaultVersion()
  local original = {
    opts = App.opts,
    state = App.state,
    fieldNew = FieldState.new,
    storeNew = GameSaveStore.new,
    oakCompose = OakIntroComposition.compose,
  }
  if App.state and App.state.state then
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

  rawset(GameSaveStore, "new", function()
    return store
  end)
  rawset(OakIntroComposition, "compose", function(composeOptions)
    local input = {}
    for key, value in pairs(composeOptions) do
      input[key] = value
    end
    controller = OakIntroController.new({
      candidate = composeOptions.candidate,
      clock = clock,
      audio = audio --[[@as GameSound]],
      messages = MESSAGES,
      assets = INTRO_ASSETS,
      virtualGlyphs = VIRTUAL_GLYPHS,
      playerDataContext = PLAYER_DATA_CONTEXT,
      randomU32 = function()
        return 0x12345678
      end,
    })
    input.controller = controller
    input.manifest = INTRO_MANIFEST
    input.renderer = renderer
    input.textInputHost = inputHost
    input.glyphs = VIRTUAL_GLYPHS
    input.width = options.width or 960
    input.height = options.height or 540
    ---@cast input OakIntroStateOptions
    return OakIntroState.new(input)
  end)
  App.opts = {
    test = false,
    actors = false,
    dev = false,
  }
  ---@diagnostic disable-next-line: duplicate-set-field
  FieldState.new = function(game, fieldOptions)
    fieldCalls[#fieldCalls + 1] = { game = game, options = fieldOptions }
    return { kind = "field" }
  end

  local ok, err = xpcall(function()
    App._bootMainMenu({ readyVersion })
    Assert.equal(App.state.state:view().kind, "main_menu")
    App.keypressed("return")
    Assert.notNil(controller, "New Game must enter the real Oak controller boundary")
    Assert.equal(App.state.state.controller, controller)
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
  FieldState.new = original.fieldNew
  GameSaveStore.new = original.storeNew
  OakIntroComposition.compose = original.oakCompose
  if not ok then
    error(err, 0)
  end
end

local function advance(frames)
  Assert.isTrue(App.state ~= nil, "Oak flow ended before the requested source frames")
  App.state.state:tick(frames)
end

local function advanceUntilPhase(phase)
  for _ = 1, 2000 do
    if App.state.state:view().phase == phase then
      return
    end
    advance(1)
  end
  error("Oak flow did not reach phase: " .. phase)
end

local function confirm()
  App.keypressed("return")
end

-- Navigates keyboard focus onto the virtual Confirm key before activating
-- it, matching the one confirm-capable-device contract (keyboard/gamepad
-- both activate the focused virtual key rather than submitting directly).
local function submitName()
  App.keypressed("left")
  confirm()
end

local function reachGenderSelect(audio)
  advance(40)
  confirm()
  -- These scenarios exercise profile input after the fade; the dedicated
  -- audio scenario controls this host completion explicitly.
  audio.fadeActive = false
  advance(6 + 30)
  confirm()
  advance(26)
  confirm()
  advanceUntilPhase("oak_live_alongside")
  confirm()
  advanceUntilPhase("oak_tell_about_yourself")
  confirm()
  confirm()
  advance(26)
  Assert.equal(App.state.state:view().phase, "gender_select")
end

local function reachNameEditor(audio)
  reachGenderSelect(audio)
  confirm()
  confirm()
  confirm()
  advance(40)
  Assert.equal(App.state.state:view().phase, "name_edit")
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
    advance(6 + 30)
    Assert.equal(context.controller:view().message, MESSAGES["oak.welcome"])
    confirm()
    advance(26)
    Assert.equal(context.controller:view().message, MESSAGES["oak.world_inhabited"])
    confirm()
    advanceUntilPhase("oak_live_alongside")
    Assert.equal(context.controller:view().message, MESSAGES["oak.live_alongside"])
    confirm()
    advanceUntilPhase("oak_tell_about_yourself")
    Assert.equal(context.controller:view().message, MESSAGES["oak.tell_about_yourself"])
    confirm()

    Assert.equal(context.controller:view().phase, "gender_question")

    confirm()
    advance(26)
    confirm()
    confirm()
    confirm()
    confirm()
    advanceUntilPhase("name_edit")
    Assert.equal(context.controller:view().phase, "name_edit")
    App.textinput("GOLD")
    Assert.equal(context.controller:view().name, "GOLD")
    submitName()
    advance(26)
    confirm()
    confirm()
    advance(1 + 1 + 30 + 9 * 4)
    Assert.equal(#context.fieldCalls, 1)
    Assert.equal(context.fieldCalls[1].game.playerData.profile.name, "GOLD")
    Assert.equal(App.state.state.kind, "field")
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
    Assert.equal(App.state.state:view().phase, "gender_confirm")
    App.gamepadpressed({}, "b")
    Assert.equal(App.state.state:view().phase, "gender_question")
    confirm()
    Assert.equal(App.state.state:view().phase, "gender_select")
    Assert.equal(App.state.state:view().genderFocus, 1)

    confirm()
    confirm()
    confirm()
    advance(40)
    App.textinput("GOLD")
    submitName()
    advance(26)
    Assert.equal(App.state.state:view().phase, "name_confirm")
    App.keypressed("escape")
    Assert.equal(App.state.state:view().phase, "gender_question")
    confirm()
    advance(26)
    confirm()
    confirm()
    confirm()
    advance(40)
    Assert.equal(App.state.state:view().phase, "name_edit")
    Assert.equal(App.state.state:view().name, "")

    Assert.isNil(context.controller:candidate().playerData)
  end)
end

function T.tests.name_submission_exits_composition_before_confirm_and_rejection_reenters_it()
  startFlow({}, function(context)
    reachNameEditor(context.audio)
    Assert.equal(App.state.state:view().genderCompositionProgress, 1)
    App.textinput("GOLD")
    submitName()
    Assert.isFalse(App.state.state:view().phase == "name_confirm", "name_confirm must wait for the composition exit")

    for _ = 1, 25 do
      advance(1)
      Assert.isFalse(
        App.state.state:view().phase == "name_confirm",
        "name_confirm must not open before progress reaches 0"
      )
    end
    advance(1)
    Assert.equal(App.state.state:view().phase, "name_confirm")
    Assert.equal(App.state.state:view().genderCompositionProgress, 0)
    local layout = App.state.state:view().layout
    Assert.isNil(layout.oakRegion, "ordinary Oak name-confirm presentation must not retain a split region")
    Assert.isNil(layout.selectorRegion, "ordinary Oak name-confirm presentation must not retain a selector region")

    App.keypressed("escape")
    Assert.equal(App.state.state:view().phase, "gender_question")
    Assert.equal(App.state.state:view().genderCompositionProgress, 0)

    confirm()
    Assert.equal(App.state.state:view().phase, "gender_composition_transition")
    Assert.equal(App.state.state:view().genderCompositionProgress, 0)
    advance(26)
    Assert.equal(App.state.state:view().phase, "gender_select")
    Assert.equal(App.state.state:view().genderCompositionProgress, 1)
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
    Assert.equal(context.controller:view().phase, "oak_welcome")
    confirm()
    advance(26)
    Assert.equal(context.controller:view().phase, "oak_world_inhabited")
    confirm()
    advance(30)
    Assert.equal(context.controller:view().phase, "scene_flash")
    advanceUntilPhase("marill_appear")
    advanceUntilPhase("marill_cry_wait")
    Assert.equal(context.controller:view().phase, "marill_cry_wait")
    Assert.deepEqual(context.audio.events[#context.audio.events - 1], { name = "effect", value = "SEQ_SE_DP_BOWA2" })
    Assert.deepEqual(context.audio.events[#context.audio.events], { name = "cry", value = { species = 184, form = 0 } })
    advanceUntilPhase("oak_live_alongside")
    Assert.equal(context.controller:view().phase, "oak_live_alongside")
  end)
end

function T.tests.final_confirmation_hands_off_a_valid_unpublished_game()
  startFlow({}, function(context)
    reachNameEditor(context.audio)
    App.textinput("GOLD")
    submitName()
    advance(26)
    Assert.equal(App.state.state:view().phase, "name_confirm")
    confirm()
    Assert.equal(App.state.state:view().phase, "final_dialogue")
    confirm()
    Assert.equal(App.state.state:view().phase, "final_fade_out")
    Assert.isNil(context.controller:candidate().playerData)
    advance(1)
    Assert.equal(App.state.state:view().phase, "final_full_art_fade_in")
    advance(1 + 30 + 9 * 4)

    Assert.equal(App.state.state.kind, "field")
    Assert.equal(#context.fieldCalls, 1)
    local result = context.fieldCalls[1].game
    Assert.equal(result.saveId, "save-00000027")
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
    Assert.equal(App.state.state:view().phase, "gender_confirm")
    App.keypressed("escape")
    confirm()
    Assert.equal(App.state.state:view().genderFocus, 1)
    App.resize(420, 800)
    Assert.equal(App.state.state:view().layout.viewport.width, 420)
    Assert.equal(App.state.state:view().genderFocus, 1)
    local card = App.state.state:view().layout.cards[App.state.state:view().genderFocus]
    App.state.state:touchpressed("finger-1", card.x + 1, card.y + 1)
    Assert.equal(App.state.state:view().phase, "gender_confirm")

    confirm()
    confirm()
    advance(40)
    Assert.equal(App.state.state:view().phase, "name_edit")
    App.textinput("A")
    local layout = App.state.state:view().layout
    local key
    for _, entry in pairs(layout.nameGrid) do
      if entry.glyph == "é" then
        key = entry.rect
        break
      end
    end
    Assert.notNil(key)
    App.state.state:mousepressed(key.x + 1, key.y + 1, 1)
    Assert.equal(App.state.state:view().name, "Aé")
    App.keypressed("backspace")
    Assert.equal(App.state.state:view().name, "A")
    App.gamepadpressed({}, "a")
    Assert.equal(App.state.state:view().name, "AA")
    Assert.deepEqual(context.inputHost.calls, { false, true })
    Assert.equal(context.renderer.disposed, 0)
  end)
end

return T
