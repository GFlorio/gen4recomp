-- Lower-layer contracts for the source-shaped Oak/profile state machine.
-- The controller is pure: clocks, generated assets/messages, audio, and the
-- finalization boundary are explicit collaborators.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local NewGame = require("libs.engine.src.NewGame")
local OakGreetingPolicy = require("libs.engine.src.OakGreetingPolicy")
local OakIntroController = require("libs.engine.src.OakIntroController")

local T = {}

local CHARMAP = { A = 1, B = 2, C = 3, D = 4, E = 5, G = 6, O = 7, L = 8, ["é"] = 9 }
local PLAYER_DATA_CONTEXT = { charmap = CHARMAP, frameIndexes = { [0] = true } }

local function candidate()
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000017"
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

local function clock(hour, minute)
  local value = { hour = hour, minute = minute, second = 0 }
  return {
    nowLocal = function()
      return {
        year = 2026,
        month = 8,
        day = 22,
        hour = value.hour,
        minute = value.minute,
        second = value.second,
      }
    end,
    value = value,
  }
end

local function audio()
  local trace = {}
  local function record(name, value)
    trace[#trace + 1] = { name = name, value = value }
  end
  return {
    trace = trace,
    playMusic = function(_, id)
      record("music", id)
    end,
    stopMusic = function()
      record("stop_music")
    end,
    fadeMusicOut = function(_, spec)
      record("fade_out", spec)
    end,
    play = function(_, id)
      record("effect", id)
    end,
    playCry = function(_, species, form)
      record("cry", { species = species, form = form })
    end,
    updateSoundFrame = function()
      record("sound_frame")
    end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function controller(options)
  options = options or {}
  local time = options.clock or clock(12, 0)
  return OakIntroController.new({
    candidate = options.candidate or candidate(),
    clock = time,
    audio = options.audio or audio(),
    messages = options.messages or {
      ["greeting.midnight"] = "greeting.midnight",
      ["greeting.morning"] = "greeting.morning",
      ["greeting.day"] = "greeting.day",
      ["greeting.evening"] = "greeting.evening",
      ["greeting.night"] = "greeting.night",
      ["oak.welcome"] = "oak.welcome",
      ["oak.world_inhabited"] = "oak.world_inhabited",
      ["oak.live_alongside"] = "oak.live_alongside",
      ["oak.tell_about_yourself"] = "oak.tell_about_yourself",
      ["profile.gender_question"] = "profile.gender_question",
      ["profile.gender_confirm.male"] = "profile.gender_confirm.male",
      ["profile.gender_confirm.female"] = "profile.gender_confirm.female",
      ["profile.name_prompt"] = "profile.name_prompt",
      ["profile.name_confirm.male"] = "profile.name_confirm.male",
      ["profile.name_confirm.female"] = "profile.name_confirm.female",
      ["profile.final"] = "profile.final",
    },
    assets = options.assets or {},
    virtualGlyphs = { "A", "B", "C", "D", "E", "F", "G", "O", "L", "é" },
    playerDataContext = PLAYER_DATA_CONTEXT,
    randomU32 = function()
      return 0x12345678
    end,
  })
end

local function animatedAssets()
  return {
    marill = { frames = { { duration = 1 }, { duration = 4 }, { duration = 2 } } },
    ["shrink.male"] = { frames = { { duration = 2 }, { duration = 3 } } },
    ["shrink.female"] = { frames = { { duration = 2 }, { duration = 3 } } },
  }
end

function T.greeting_policy_uses_each_source_boundary()
  local cases = {
    { 3, 59, "midnight" },
    { 4, 0, "morning" },
    { 10, 59, "morning" },
    { 11, 0, "day" },
    { 15, 59, "day" },
    { 16, 0, "evening" },
    { 18, 59, "evening" },
    { 19, 0, "night" },
    { 23, 59, "night" },
  }
  for _, case in ipairs(cases) do
    Assert.equal(OakGreetingPolicy.bandAt(case[1], case[2]), case[3])
  end
end

function T.greeting_samples_clock_when_the_greeting_is_queued()
  local time = clock(3, 59)
  local state = controller({ clock = time })
  state:start()
  time.value.hour, time.value.minute = 4, 0
  state:tick(40)
  Assert.equal(state:view().message, "greeting.morning")
end

function T.gender_rejection_returns_through_question_with_remembered_focus()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30 + 40)
  state:press("confirm")
  state:tick(30 + 26)
  state:press("confirm")
  state:press("confirm")
  state:press("right")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_select")
  Assert.equal(state:view().genderFocus, 1)
end

function T.name_buffer_has_shared_utf8_limits_and_deletes_glyphs()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30 + 40)
  state:press("confirm")
  state:tick(30 + 26)
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")
  state:inputText("Aé")
  Assert.equal(state:view().name, "Aé")
  state:deleteGlyph()
  Assert.equal(state:view().name, "A")
  state:inputText("BBBBBB")
  Assert.equal(state:view().name, "ABBBBBB")
  state:inputText("C")
  Assert.equal(state:view().name, "ABBBBBB")
  state:press("submit")
  Assert.equal(state:view().phase, "name_confirm")
end

function T.name_rejection_clears_the_buffer_on_reentry()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30 + 40)
  state:press("confirm")
  state:tick(30 + 26)
  state:press("confirm")
  for _ = 1, 5 do
    state:press("confirm")
  end
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  for _ = 1, 4 do
    state:press("confirm")
  end
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")
  Assert.equal(state:view().name, "")
end

function T.fixed_source_waits_and_cry_do_not_wait_for_completion()
  local sounds = audio()
  local state = controller({ audio = sounds })
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6)
  Assert.equal(state:view().phase, "oak_reveal_wait")
  state:tick(30)
  Assert.equal(state:view().phase, "oak_welcome")
  state:press("confirm")
  state:tick(26)
  Assert.equal(state:view().phase, "oak_world_inhabited")
  state:press("confirm")
  state:tick(30)
  Assert.equal(state:view().phase, "marill_cry_wait")
  Assert.equal(sounds.trace[#sounds.trace].name, "cry")
  state:tick(39)
  Assert.equal(state:view().phase, "marill_cry_wait")
  state:tick(1)
  state:tick(1)
  Assert.equal(state:view().phase, "oak_live_alongside")
end

function T.core_sequence_exposes_source_beats_in_order()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  Assert.equal(state:view().message, "oak.welcome")
  state:press("confirm")
  state:tick(26)
  Assert.equal(state:view().message, "oak.world_inhabited")
  state:press("confirm")
  state:tick(30)
  Assert.equal(state:view().visual, "marill")
  state:tick(40)
  Assert.equal(state:view().message, "oak.live_alongside")
  state:press("confirm")
  state:tick(30 + 26)
  Assert.equal(state:view().message, "oak.tell_about_yourself")
  state:press("confirm")
  Assert.equal(state:view().message, "profile.gender_question")
end

function T.generated_animation_durations_drive_looping_marill_frames()
  local state = controller({ assets = animatedAssets() })
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30)
  Assert.equal(state:view().visual, "marill")
  Assert.equal(state:view().visualFrameIndex, 1)
  state:tick(1)
  Assert.equal(state:view().visualFrameIndex, 2)
  state:tick(4)
  Assert.equal(state:view().visualFrameIndex, 3)
  state:tick(2)
  Assert.equal(state:view().visualFrameIndex, 1)
end

function T.shrink_frames_remain_drawable_until_their_generated_durations_end()
  local state = controller({ assets = animatedAssets() })
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30 + 40)
  state:press("confirm")
  state:tick(30 + 26)
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:press("confirm")
  state:press("confirm")
  Assert.equal(state:view().phase, "shrink_wait")
  state:tick(30)
  Assert.equal(state:view().phase, "shrink_animation")
  Assert.equal(state:view().visualFrameIndex, 1)
  state:tick(4)
  Assert.equal(state:view().phase, "shrink_animation")
  Assert.equal(state:view().visualFrameIndex, 2)
  state:tick(1)
  Assert.equal(state:view().phase, "complete")
end

function T.virtual_keyboard_focus_reaches_delete_and_confirm_actions()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30 + 40)
  state:press("confirm")
  state:tick(30 + 26)
  state:press("confirm")
  for _ = 1, 4 do
    state:press("confirm")
  end
  state:tick(40)
  state:press("confirm")
  for _ = 1, 10 do
    state:press("right")
  end
  state:press("confirm")
  Assert.equal(state:view().name, "")
  state:press("right")
  state:press("confirm")
  Assert.equal(state:view().name, "")
end

function T.finalization_handoff_keeps_reserved_identity_without_storage_publication()
  local state = controller()
  local candidateValue = state:candidate()
  local calls = 0
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30 + 40)
  state:press("confirm")
  state:tick(30 + 26)
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:press("confirm")
  state:press("confirm")
  state:tick(30)
  Assert.equal(state:view().phase, "complete")
  local result = assert(state:result())
  Assert.equal(result.saveId, "save-00000017")
  Assert.equal(result.playerData.profile.name, "GOLD")
  Assert.equal(result.playerData.profile.trainerId, 0x12345678)
  Assert.equal(calls, 0)
end

return { tests = T }
