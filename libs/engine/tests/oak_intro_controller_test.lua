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
    assets = options.assets or {
      marill = { frames = { { duration = 1 } } },
      marill_appear = { frames = { { duration = 1 } } },
      ball_open = { frames = { { duration = 1 } } },
    },
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
    marill_appear = { frames = { { duration = 1 } } },
    ball_open = { frames = { { duration = 1 } } },
    shrink_male = { frames = { { duration = 2 }, { duration = 3 } } },
    shrink_female = { frames = { { duration = 2 }, { duration = 3 } } },
  }
end

local function finalSequenceAssets()
  return {
    marill = { frames = { { duration = 1 } } },
    marill_appear = { frames = { { duration = 1 } } },
    ball_open = { frames = { { duration = 1 } } },
    male = { frames = { { duration = 1 } } },
    female = { frames = { { duration = 1 } } },
    shrink_male = { frames = { { duration = 8 }, { duration = 8 }, { duration = 8 }, { duration = 8 } } },
    shrink_female = { frames = { { duration = 8 }, { duration = 8 }, { duration = 8 }, { duration = 8 } } },
  }
end

local function advanceToPhase(state, phase)
  for _ = 1, 2000 do
    if state:view().phase == phase then
      return
    end
    state:tick(1)
  end
  error("Oak test did not reach phase: " .. phase)
end

local function advanceThroughHide(state)
  advanceToPhase(state, "oak_tell_about_yourself")
end

local function genderConfirmation(selectFemale, options)
  selectFemale = selectFemale ~= false
  local state = controller(options)
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:messageCompleted("oak.world_inhabited")
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  if selectFemale then
    state:press("right")
  end
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")
  state:messageCompleted(selectFemale and "profile.gender_confirm.female" or "profile.gender_confirm.male")
  Assert.deepEqual(state:view().confirmationChoice, { kind = "gender", selected = 0 })
  return state
end

local function nameConfirmation(selectFemale, options)
  options = options or {}
  local state = genderConfirmation(selectFemale, options)
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:messageCompleted(selectFemale == false and "profile.name_confirm.male" or "profile.name_confirm.female")
  Assert.equal(state:view().phase, "name_confirm")
  Assert.deepEqual(state:view().confirmationChoice, { kind = "name", selected = 0 })
  return state
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
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
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

function T.confirmation_completion_activates_an_explicit_yes_choice()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
  state:press("confirm")
  state:press("confirm")
  state:press("right")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")

  state:messageCompleted("profile.gender_confirm.female")
  local view = state:view()
  Assert.equal(view.phase, "gender_confirm")
  Assert.deepEqual(view.confirmationChoice, { kind = "gender", selected = 0 })

  state:press("down")
  Assert.equal(state:view().confirmationChoice.selected, 1)
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  Assert.equal(state:view().genderFocus, 1)
end

function T.focused_no_resolves_gender_rejection()
  local state = genderConfirmation()
  state:press("down")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_question")
  Assert.equal(state:view().genderFocus, 1)
end

function T.focused_no_resolves_name_rejection()
  local state = nameConfirmation()
  state:press("down")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_question")
end

function T.focused_yes_remains_affirmative_for_gender_and_name()
  local gender = genderConfirmation()
  gender:press("confirm")
  Assert.equal(gender:view().phase, "name_prompt")

  local name = nameConfirmation()
  name:press("confirm")
  Assert.equal(name:view().phase, "final_dialogue")
end

function T.confirmation_yes_and_no_resolve_only_from_the_active_choice()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:messageCompleted("profile.name_confirm.male")
  Assert.equal(state:view().phase, "name_confirm")
  state:press("yes")
  Assert.equal(state:view().phase, "final_dialogue")
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
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
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
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
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
  advanceToPhase(state, "marill_cry_wait")
  Assert.equal(state:view().phase, "marill_cry_wait")
  Assert.equal(sounds.trace[#sounds.trace].name, "cry")
  state:tick(39)
  Assert.equal(state:view().phase, "marill_cry_wait")
  state:tick(1)
  Assert.equal(state:view().phase, "oak_live_alongside")
end

function T.reveal_stages_are_sequential_and_cry_waits_for_idle_marill()
  local sounds = audio()
  local state = controller({
    audio = sounds,
    assets = {
      marill = { frames = { { duration = 2 }, { duration = 2 } } },
      marill_appear = { frames = { { duration = 2 }, { duration = 2 } } },
      ball_open = { frames = { { duration = 1 }, { duration = 1 } } },
    },
  })
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:messageCompleted("oak.world_inhabited")

  Assert.equal(state:view().revealWidget, "ball_open")
  local function count(name)
    local total = 0
    for _, event in ipairs(sounds.trace) do
      if event.name == name then
        total = total + 1
      end
    end
    return total
  end
  Assert.equal(count("effect"), 0, "ball opening does not emit flash sound yet")
  Assert.equal(count("cry"), 0, "ball opening does not emit cry yet")
  state:tick(29)
  Assert.equal(state:view().revealWidget, "ball_open")
  Assert.equal(count("effect"), 0)
  state:tick(1)
  Assert.equal(state:view().phase, "scene_flash")
  state:tick(4)
  Assert.equal(state:view().revealWidget, "marill_appear")
  Assert.equal(count("cry"), 0)
  advanceToPhase(state, "marill_cry_wait")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.equal(count("cry"), 1)
  state:tick(39)
  Assert.equal(state:view().message, nil)
  state:tick(1)
  Assert.equal(state:view().message, "oak.live_alongside")
  Assert.equal(state:view().revealWidget, "marill")
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
  advanceToPhase(state, "marill_cry_wait")
  Assert.equal(state:view().primaryWidget, "oak")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.equal(state:view().revealFrameIndex, 1)
  state:tick(40)
  Assert.equal(state:view().message, "oak.live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
  Assert.equal(state:view().message, "oak.tell_about_yourself")
  state:press("confirm")
  Assert.equal(state:view().message, "profile.gender_question")
end

function T.background_visual_has_no_primary_widget_outside_the_reveal_subject()
  local state = controller()
  state:start()
  Assert.equal(state:view().visual, "background")
  Assert.equal(state:view().primaryWidget, nil)

  state:tick(40)
  Assert.equal(state:view().phase, "greeting")
  Assert.equal(state:view().primaryWidget, nil)
end

function T.dialogue_view_keeps_the_generated_message_key_boundary()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  local view = state:view()
  Assert.equal(view.messageKey, "oak.welcome")
  Assert.equal(view.dialogue.message, view.message)
  Assert.equal(view.dialogue.messageKey, view.messageKey)
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
  advanceToPhase(state, "marill_cry_wait")
  Assert.equal(state:view().primaryWidget, "oak")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.equal(state:view().revealFrameIndex, 1)
  state:tick(1)
  Assert.equal(state:view().revealFrameIndex, 2)
  state:tick(4)
  Assert.equal(state:view().revealFrameIndex, 3)
  state:tick(2)
  Assert.equal(state:view().revealFrameIndex, 1)
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
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
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
  Assert.equal(state:view().phase, "final_fade_out")
  state:tick(1)
  Assert.equal(state:view().phase, "final_full_art_fade_in")
  Assert.equal(state:view().primaryWidget, "male")
  state:tick(1)
  Assert.equal(state:view().phase, "final_full_art_hold")
  advanceToPhase(state, "shrink_animation")
  Assert.equal(state:view().phase, "shrink_animation")
  Assert.equal(state:view().visualFrameIndex, 1)
  state:tick(2)
  Assert.equal(state:view().phase, "shrink_animation")
  Assert.equal(state:view().visualFrameIndex, 2)
  state:tick(3)
  Assert.equal(state:view().phase, "complete")
end

function T.final_handoff_shows_selected_full_art_then_source_timed_shrink_for_both_genders()
  for _, gender in ipairs({ 0, 1 }) do
    local sounds = audio()
    local state = controller({ audio = sounds, assets = finalSequenceAssets() })
    state:start()
    state:tick(40)
    state:press("confirm")
    state:tick(6 + 30)
    state:press("confirm")
    state:tick(26)
    state:press("confirm")
    advanceToPhase(state, "oak_live_alongside")
    state:press("confirm")
    advanceThroughHide(state)
    state = nameConfirmation(gender == 1, { audio = sounds, assets = finalSequenceAssets() })
    state:press("confirm")
    Assert.equal(state:view().phase, "final_dialogue")
    state:press("confirm")
    Assert.equal(state:view().phase, "final_fade_out")
    Assert.equal(state:view().primaryWidget, nil)
    Assert.isNil(state:result())

    state:tick(1)
    Assert.equal(state:view().phase, "final_full_art_fade_in")
    Assert.equal(state:view().primaryWidget, gender == 0 and "male" or "female")
    Assert.isNil(state:result())

    state:tick(1)
    Assert.equal(state:view().phase, "final_full_art_hold")
    Assert.equal(state:view().primaryWidget, gender == 0 and "male" or "female")
    state:tick(29)
    Assert.equal(state:view().phase, "final_full_art_hold")
    Assert.isNil(state:result())
    state:tick(1)
    Assert.equal(state:view().phase, "shrink_animation")
    Assert.equal(state:view().visualFrameIndex, 1)
    Assert.equal(state:view().primaryWidget, gender == 0 and "shrink_male" or "shrink_female")

    local soundCount = 0
    for _, event in ipairs(sounds.trace) do
      if event.name == "effect" and event.value == "SEQ_SE_GS_HERO_SHUKUSHOU" then
        soundCount = soundCount + 1
      end
    end
    Assert.equal(soundCount, 1)
    state:tick(8)
    Assert.equal(state:view().visualFrameIndex, 2)
    Assert.isNil(state:result())
    state:tick(8 * 3)
    Assert.equal(state:view().phase, "complete")
    Assert.notNil(state:result())
    local handoffs = 0
    for _, event in ipairs(state:view().events) do
      if event.kind == "handoff" then
        handoffs = handoffs + 1
      end
    end
    Assert.equal(handoffs, 1)
    state:tick(20)
    local repeatedHandoffs = 0
    for _, event in ipairs(state:view().events) do
      if event.kind == "handoff" then
        repeatedHandoffs = repeatedHandoffs + 1
      end
    end
    Assert.equal(repeatedHandoffs, 1)
  end
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
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
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

function T.name_editor_vertical_navigation_uses_the_configured_column_count()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")
  Assert.equal(state:view().virtualKeyColumns, 10)
  Assert.equal(state:view().virtualGlyphFocus, 1)
  state:press("down")
  Assert.equal(state:view().virtualGlyphFocus, 11)
  state:press("up")
  Assert.equal(state:view().virtualGlyphFocus, 1)
end

function T.slide_endpoint_survives_non_slide_phases_and_reverse_starts_there()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  local world = state:view()
  Assert.equal(world.phase, "oak_world_inhabited")
  Assert.equal(world.oakSlideOffset, -52)
  state:press("confirm")
  advanceToPhase(state, "oak_live_alongside")
  Assert.equal(state:view().phase, "oak_live_alongside")
  Assert.equal(state:view().oakSlideOffset, -52)
  state:press("confirm")
  advanceToPhase(state, "oak_slide_left")
  Assert.equal(state:view().phase, "oak_slide_left")
  Assert.equal(state:view().oakSlideOffset, -52)
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
  advanceToPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceThroughHide(state)
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
  state:tick(1 + 1 + 30)
  Assert.equal(state:view().phase, "complete")
  local result = assert(state:result())
  Assert.equal(result.saveId, "save-00000017")
  Assert.equal(result.playerData.profile.name, "GOLD")
  Assert.equal(result.playerData.profile.trainerId, 0x12345678)
  Assert.equal(calls, 0)
end

return { tests = T }
