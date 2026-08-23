-- Acceptance contracts for the host-native Oak presentation. These scenarios
-- use the real schema validator and production layout/controller/state modules;
-- image, audio, clock, and renderer collaborators are deterministic fixtures.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local NewGame = require("libs.engine.src.NewGame")
local OakIntroController = require("libs.engine.src.OakIntroController")
local OakIntroLayout = require("game.src.game.OakIntroLayout")
local OakIntroState = require("game.src.game.OakIntroState")

local T = {
  metadata = {
    tags = { "oak", "responsive", "production-composition" },
  },
  tests = {},
}

local REQUIRED = { "oak", "marill", "male", "female", "shrink_male", "shrink_female", "ball_open" }
local MESSAGES = {
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
}

local function candidate()
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-acceptance-d03"
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

local function manifest()
  local widgets = {}
  for index, id in ipairs(REQUIRED) do
    widgets[id] = {
      image = "assets/generated/intro/" .. id .. ".png",
      width = 32 + index,
      height = 48 + index,
      sampling = "nearest",
      anchor = { x = (32 + index) / 2, y = 48 + index },
      sourceBounds = { x = index, y = index, width = 32 + index, height = 48 + index },
      frames = {
        {
          image = "assets/generated/intro/" .. id .. ".png",
          width = 32 + index,
          height = 48 + index,
          duration = 1,
          anchor = { x = (32 + index) / 2, y = 48 + index },
        },
      },
    }
  end
  return {
    schemaVersion = 2,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = {
      image = "assets/generated/intro/background.png",
      width = 1,
      height = 192,
      sampling = "linear",
    },
    widgets = widgets,
  }
end

local function audio()
  local trace = {}
  local active = false
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
      active = false
    end,
    play = function(_, id)
      record("effect", id)
    end,
    playCry = function(_, species, form)
      record("cry", { species = species, form = form })
    end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return active
    end,
  }
end

local function controller(options)
  options = options or {}
  return OakIntroController.new({
    candidate = candidate(),
    clock = {
      nowLocal = function()
        return { hour = 12, minute = 0 }
      end,
    },
    audio = options.audio or audio(),
    messages = MESSAGES,
    assets = {
      oak = { frames = { { duration = 1 } } },
      marill = { frames = { { duration = 1 } } },
      ["shrink.male"] = { frames = { { duration = 1 } } },
      ["shrink.female"] = { frames = { { duration = 1 } } },
    },
    playerDataContext = { charmap = { A = 1, B = 2, G = 3, O = 4, L = 5 }, frameIndexes = { [0] = true } },
    randomU32 = function()
      return 0x12345678
    end,
    virtualGlyphs = { "A", "B", "G", "O", "L" },
  })
end

local function recordingRenderer()
  return {
    draw = function() end,
    dispose = function() end,
  }
end

local function assertFiniteInside(region, bounds)
  Assert.isTrue(region.x == region.x and region.y == region.y)
  Assert.isTrue(region.width > 0 and region.height > 0)
  Assert.isTrue(region.x >= bounds.x and region.y >= bounds.y)
  Assert.isTrue(region.x + region.width <= bounds.x + bounds.width)
  Assert.isTrue(region.y + region.height <= bounds.y + bounds.height)
end

function T.tests.host_native_layout_contract_across_representative_viewports()
  local checked = IntroAssetCache.validateManifest(manifest())
  Assert.isTrue(checked, "scenario requires a valid schema-2 semantic manifest")
  for _, size in ipairs({ { 320, 240 }, { 390, 844 }, { 800, 600 }, { 1920, 1080 }, { 2560, 1080 } }) do
    local state = OakIntroState.new({
      controller = controller(),
      manifest = manifest(),
      renderer = recordingRenderer(),
      textRenderer = {},
      glyphs = { "A", "B" },
      width = size[1],
      height = size[2],
      textInputHost = { setTextInput = function() end },
    })
    local view = state:view()
    Assert.notNil(view.layout.safeFrame)
    Assert.notNil(view.layout.stageContent)
    Assert.isTrue(view.layout.stageContent.width <= 1120)
    assertFiniteInside(view.layout.stageContent, view.layout.safeFrame)
    state:dispose()
  end
end

function T.tests.dialogue_contract_preserves_tokens_prompts_and_substitution_boundary()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  Assert.equal(state:view().message, "oak.welcome")
  Assert.notNil(state:view().dialogue, "Oak state must expose the shared dialogue presentation")
  Assert.notNil(state:view().messageKey)
  Assert.isFalse(tostring(state:view().message):find("STRVAR", 1, true) ~= nil)
end

function T.tests.ball_reveal_is_an_overlay_with_source_timed_slide_and_single_sound()
  local sound = audio()
  local state = controller({ audio = sound })
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  Assert.equal(state:view().phase, "ball_open_wait")
  Assert.equal(state:view().primaryWidget, "oak")
  Assert.isNil(state:view().overlayWidget)
  state:tick(30)
  Assert.equal(state:view().overlayWidget, "ball_open")
  local effects = 0
  for _, event in ipairs(sound.trace) do
    if event.name == "effect" and event.value == "SEQ_SE_DP_BOWA2" then
      effects = effects + 1
    end
  end
  Assert.equal(effects, 1)
end

function T.tests.profile_and_name_controls_share_explicit_draw_and_hit_rectangles()
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
  Assert.equal(state:view().phase, "gender_select")
  Assert.notNil(OakIntroLayout.compute(390, 844, state:view(), { "A", "B" }).profileCards)
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")
  local layout = OakIntroLayout.compute(390, 844, state:view(), { "A", "B" })
  Assert.notNil(layout.nameKeys)
  Assert.equal(layout.nameKeys[1].label, "A")
end

return T
