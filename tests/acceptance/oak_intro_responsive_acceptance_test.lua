-- Acceptance contracts for the host-native Oak presentation. These scenarios
-- use the real schema validator and production layout/controller/state modules;
-- image, audio, clock, and renderer collaborators are deterministic fixtures.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")
local FakeGraphics = require("tests.support.FakeGraphics")

local T = {
  metadata = {
    tags = { "oak", "responsive", "production-composition" },
    capabilities = { "rom_dump", "derived_cache" },
  },
  tests = {},
}

local REQUIRED = {
  "oak",
  "marill",
  "marill_appear",
  "male",
  "female",
  "shrink_male",
  "shrink_female",
  "ball_open",
  "gender_male",
  "gender_female",
}
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
        return "save-acceptance-oak"
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

local manifest

local function genderView()
  return {
    phase = "gender_select",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = 1,
    oakBgScrollX = 0,
  }
end

local function genderManifest()
  local data = manifest()
  local widgets = data.widgets
  widgets.gender_male = {
    image = "assets/generated/intro/gender-male.png",
    sampling = "nearest",
    width = 64,
    height = 96,
    anchor = { x = 32, y = 48 },
    sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
    sourceCenter = { x = 64, y = 104 },
    frames = {
      {
        image = "assets/generated/intro/gender-male.png",
        width = 64,
        height = 96,
        duration = 1,
        element = "none",
        translateX = 0,
        translateY = 0,
        scaleX = 1,
        scaleY = 1,
        rotation = 0,
      },
    },
  }
  widgets.gender_female = {
    image = "assets/generated/intro/gender-female.png",
    sampling = "nearest",
    width = 64,
    height = 96,
    anchor = { x = 32, y = 48 },
    sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
    sourceCenter = { x = 192, y = 104 },
    frames = {
      {
        image = "assets/generated/intro/gender-female.png",
        width = 64,
        height = 96,
        duration = 1,
        element = "none",
        translateX = 0,
        translateY = 0,
        scaleX = 1,
        scaleY = 1,
        rotation = 0,
      },
    },
  }
  return data
end

---@param inner OakIntroStateRectangle
---@param outer OakIntroStateRectangle
---@param message string
local function assertInside(inner, outer, message)
  Assert.isTrue(inner.x >= outer.x, message .. " x start")
  Assert.isTrue(inner.y >= outer.y, message .. " y start")
  Assert.isTrue(inner.x + inner.width <= outer.x + outer.width, message .. " x end")
  Assert.isTrue(inner.y + inner.height <= outer.y + outer.height, message .. " y end")
end

---@param first OakIntroStateRectangle
---@param second OakIntroStateRectangle
---@param message string
local function assertDisjoint(first, second, message)
  Assert.isTrue(
    first.x + first.width <= second.x
      or second.x + second.width <= first.x
      or first.y + first.height <= second.y
      or second.y + second.height <= first.y,
    message
  )
end

manifest = function()
  local widgets = {}
  for index, id in ipairs(REQUIRED) do
    local widgetWidth = 32 + index
    local widgetHeight = 48 + index
    local isAnimated = id == "ball_open"
      or id == "marill_appear"
      or id == "marill"
      or id == "gender_male"
      or id == "gender_female"
    widgets[id] = {
      image = "assets/generated/intro/" .. id .. ".png",
      width = widgetWidth,
      height = widgetHeight,
      sampling = "nearest",
      anchor = { x = widgetWidth / 2, y = widgetHeight },
      sourceBounds = {
        x = index,
        y = index,
        width = widgetWidth,
        height = widgetHeight,
      },
      frames = {
        {
          image = "assets/generated/intro/" .. id .. ".png",
          width = widgetWidth,
          height = widgetHeight,
          duration = 1,
          anchor = { x = widgetWidth / 2, y = widgetHeight },
          element = isAnimated and "none" or nil,
          translateX = isAnimated and 0 or nil,
          translateY = isAnimated and 0 or nil,
          scaleX = isAnimated and 1 or nil,
          scaleY = isAnimated and 1 or nil,
          rotation = isAnimated and 0 or nil,
        },
      },
    }
    if id == "ball_open" or id == "marill_appear" or id == "marill" then
      widgets[id].sourceCenter = { x = 160, y = 80 }
    elseif id == "gender_male" then
      widgets[id].sourceCenter = { x = 64, y = 104 }
    elseif id == "gender_female" then
      widgets[id].sourceCenter = { x = 192, y = 104 }
    end
  end
  return {
    schemaVersion = 10,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = {
      image = "assets/generated/intro/background.png",
      width = 1,
      height = 192,
      sampling = "linear",
    },
    genderSelector = {
      defaultTone = { r = 100, g = 101, b = 102 },
      buttons = {
        male = {
          bounds = { x = 18, y = 25, width = 93, height = 148 },
        },
        female = {
          bounds = { x = 144, y = 25, width = 95, height = 148 },
        },
      },
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
        return { year = 2026, month = 8, day = 27, hour = 12, minute = 0, second = 0 } --[[@as LocalCivilTime]]
      end,
    },
    audio = (options.audio or audio()) --[[@as GameSound]],
    messages = MESSAGES,
    assets = options.assets or {
      oak = { frames = { { duration = 1 } } },
      marill = { frames = { { duration = 1 } } },
      marill_appear = { frames = { { duration = 1 } } },
      shrink_male = { frames = { { duration = 1 } } },
      shrink_female = { frames = { { duration = 1 } } },
      ball_open = { frames = { { duration = 1 } } },
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

local function advanceUntilPhase(state, phase)
  for _ = 1, 2000 do
    if state:view().phase == phase then
      return
    end
    state:tick(1)
  end
  Assert.equal(state:view().phase, phase, "Oak intro did not reach " .. phase)
end

---@param state OakIntroController|OakIntroState
local function completeMessage(state)
  local key = assert(state:view().messageKey, "expected an active Oak message")
  local activeController = state.controller or state
  Assert.isTrue(activeController:messageCompleted(key), "Oak message completion must advance the controller")
end

---@param state OakIntroController|OakIntroState
local function confirm(state)
  if state:view().messageKey then
    completeMessage(state)
  elseif state.controller then
    ---@cast state OakIntroState
    state:keypressed("return")
  else
    state:press("confirm")
  end
end

local function advanceToNameEdit(state)
  advanceUntilPhase(state, "greeting")
  confirm(state)
  advanceUntilPhase(state, "oak_welcome")
  confirm(state)
  advanceUntilPhase(state, "oak_world_inhabited")
  confirm(state)
  advanceUntilPhase(state, "oak_live_alongside")
  confirm(state)
  advanceUntilPhase(state, "oak_tell_about_yourself")
  confirm(state)
  confirm(state)
  state:tick(26)
  confirm(state)
  confirm(state)
  confirm(state)
  confirm(state)
  advanceUntilPhase(state, "name_edit")
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
  Assert.isTrue(checked, "scenario requires a valid schema-9 semantic manifest")
  for _, size in ipairs({ { 320, 240 }, { 390, 844 }, { 800, 600 }, { 1920, 1080 }, { 2560, 1080 } }) do
    local state = OakIntroState.new({
      controller = controller(),
      manifest = manifest(),
      renderer = recordingRenderer(),
      textRenderer = {},
      choiceText = { release = function() end },
      glyphs = { "A", "B" },
      width = size[1],
      height = size[2],
      textInputHost = { setTextInput = function() end },
    })
    local view = state:view()
    Assert.notNil(view.layout.safeFrame)
    Assert.notNil(view.layout.stageContent)
    Assert.isTrue(view.layout.stageContent.width <= 1120)
    assertFiniteInside(view.layout.stageContent, view.layout.viewport)
    state:dispose()
  end
end

-- The intro uses one responsive host surface; topology-specific split tests are obsolete.
function T.tests.single_surface_gender_selection_keeps_regions_separate()
  local view = genderView()
  local data = genderManifest()
  for _, size in ipairs({ { 512, 768 }, { 390, 844 } }) do
    local layout = OakIntroLayout.compute(size[1], size[2], view, { "A" }, data)
    Assert.notNil(layout.oakRegion, "layout exposes the Oak region")
    Assert.notNil(layout.selectorRegion, "layout exposes the selector region")
    assertDisjoint(layout.oakRegion, layout.selectorRegion, "Oak and selector regions overlap")
    Assert.notNil(layout.genderButtons, "selector choices are resolved")
    for gender = 0, 1 do
      assertInside(layout.genderButtons[gender].rect, layout.selectorRegion, "selector choice leaves selector panel")
    end
  end
end

function T.tests.wide_gender_selection_is_side_by_side_and_hit_regions_are_rendered_regions()
  local view = genderView()
  local layout = OakIntroLayout.compute(1920, 1080, view, { "A" }, genderManifest())
  Assert.notNil(layout.oakRegion, "wide layout exposes the Oak region")
  Assert.notNil(layout.selectorRegion, "wide layout exposes the selector region")
  Assert.notNil(layout.genderButtons, "wide layout resolves selector choices")
  Assert.isTrue(layout.oakRegion.x < layout.selectorRegion.x, "wide layout keeps Oak left of controls")
  assertDisjoint(layout.oakRegion, layout.selectorRegion, "wide Oak and selector regions overlap")
  for gender = 0, 1 do
    assertInside(layout.genderButtons[gender].rect, layout.selectorRegion, "wide selector choice leaves selector panel")
  end
end

function T.tests.constrained_gender_selection_keeps_both_controls_and_main_context_usable()
  local view = genderView()
  for _, size in ipairs({ { 320, 240 }, { 800, 600 } }) do
    local layout = OakIntroLayout.compute(size[1], size[2], view, { "A" }, genderManifest())
    Assert.notNil(layout.oakRegion, "constrained layout exposes essential Oak context")
    Assert.notNil(layout.selectorRegion, "constrained layout exposes selector controls")
    Assert.notNil(layout.genderButtons, "constrained layout resolves both choices")
    assertInside(layout.oakRegion, layout.viewport, "constrained Oak context leaves viewport")
    assertInside(layout.selectorRegion, layout.viewport, "constrained selector leaves viewport")
    assertInside(layout.genderButtons[0].rect, layout.selectorRegion, "constrained male choice leaves controls")
    assertInside(layout.genderButtons[1].rect, layout.selectorRegion, "constrained female choice leaves controls")
    assertDisjoint(layout.genderButtons[0].rect, layout.genderButtons[1].rect, "constrained gender choices overlap")
  end
end

function T.tests.dialogue_visibility_keeps_the_main_oak_stage_stable()
  local data = manifest()
  for _, size in ipairs({ { 320, 240 }, { 390, 844 }, { 800, 600 }, { 1920, 1080 }, { 2560, 1080 } }) do
    local closed = {
      phase = "oak_slide_right",
      visual = "oak",
      primaryWidget = "oak",
      oakBgScrollX = 0,
    }
    local open = {
      phase = closed.phase,
      visual = closed.visual,
      primaryWidget = closed.primaryWidget,
      oakBgScrollX = closed.oakBgScrollX,
      dialogue = { message = "oak.welcome", messageKey = "oak.welcome" },
    }
    local closedLayout = OakIntroLayout.compute(size[1], size[2], closed, {}, data)
    local openLayout = OakIntroLayout.compute(size[1], size[2], open, {}, data)
    Assert.deepEqual(openLayout.stage, closedLayout.stage)
    Assert.near(openLayout.subject.scale, closedLayout.subject.scale)
    Assert.near(openLayout.subject.y + openLayout.subject.height, closedLayout.subject.y + closedLayout.subject.height)
  end
end

function T.tests.oak_slide_endpoint_remains_held_until_reverse_slide()
  for _, size in ipairs({ { 800, 600 }, { 390, 844 } }) do
    local state = controller()
    state:start()
    state:tick(40)
    confirm(state)
    state:tick(6 + 30)
    local centered = assert(OakIntroLayout.compute(size[1], size[2], state:view(), {}, manifest()).subject)
    confirm(state)
    state:tick(26)
    local endpoint = assert(OakIntroLayout.compute(size[1], size[2], state:view(), {}, manifest()).subject)
    Assert.isTrue(
      endpoint.x > centered.x,
      "the completed source scroll must visibly shift Oak to host-space right at " .. size[1] .. "x" .. size[2]
    )
    confirm(state)
    advanceUntilPhase(state, "oak_live_alongside")
    local held = assert(OakIntroLayout.compute(size[1], size[2], state:view(), {}, manifest()).subject)
    Assert.near(held.x, endpoint.x)
    Assert.near(held.y, endpoint.y)
    confirm(state)
    advanceUntilPhase(state, "oak_slide_left")
    local reverse = state:view()
    Assert.equal(reverse.phase, "oak_slide_left")
    local reverseStart = assert(OakIntroLayout.compute(size[1], size[2], reverse, {}, manifest()).subject)
    Assert.near(reverseStart.x, held.x)
    state:tick(1)
    local moved = assert(OakIntroLayout.compute(size[1], size[2], state:view(), {}, manifest()).subject)
    Assert.isTrue(moved.x < reverseStart.x, "reverse source scroll moves monotonically back toward the base position")
  end
end

function T.tests.dialogue_contract_preserves_tokens_prompts_and_substitution_boundary()
  local state = controller()
  state:start()
  state:tick(40)
  confirm(state)
  state:tick(6 + 30)
  Assert.equal(state:view().message, "oak.welcome")
  Assert.notNil(state:view().dialogue, "Oak state must expose the shared dialogue presentation")
  Assert.notNil(state:view().messageKey)
  Assert.isFalse(tostring(state:view().message):find("STRVAR", 1, true) ~= nil)
end

function T.tests.ball_reveal_uses_source_timed_stages_and_single_sound()
  local sound = audio()
  local state = controller({ audio = sound })
  state:start()
  state:tick(40)
  confirm(state)
  state:tick(6 + 30)
  confirm(state)
  state:tick(26)
  confirm(state)
  Assert.equal(state:view().phase, "ball_open_wait")
  Assert.equal(state:view().primaryWidget, "oak")
  Assert.equal(state:view().revealWidget, "ball_open")
  advanceUntilPhase(state, "marill_appear")
  Assert.equal(state:view().revealWidget, "marill_appear")
  local effects = 0
  for _, event in ipairs(sound.trace) do
    if event.name == "effect" and event.value == "SEQ_SE_DP_BOWA2" then
      effects = effects + 1
    end
  end
  Assert.equal(effects, 1)
end

function T.tests.source_reveal_composition_draws_distinct_semantic_stages()
  local graphics = FakeGraphics.new()
  local assets = manifest()
  local marillAppear = {}
  for key, value in pairs(assets.widgets.marill) do
    marillAppear[key] = value
  end
  marillAppear.frames = {
    {
      image = "assets/generated/intro/marill-appear.png",
      width = marillAppear.width,
      height = marillAppear.height,
      duration = 1,
    },
  }
  assets.widgets.marill_appear = marillAppear
  assets.widgets.marill_appear.image = "assets/generated/intro/marill-appear.png"
  assets.widgets.marill_appear.frames[1].image = assets.widgets.marill_appear.image
  assets.widgets.ball_open.frames[1].image = "assets/generated/intro/ball-open-0.png"
  assets.widgets.ball_open.frames[1].duration = 1
  assets.widgets.marill.frames[1].image = "assets/generated/intro/marill-0.png"
  local renderer = OakIntroRenderer.new({
    manifest = assets,
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = {
      fontDef = { lineHeight = 16 },
      drawText = function() end,
      textWidth = function()
        return 0
      end,
    },
    choiceText = {
      fontDef = {
        lineHeight = 16,
        palette = { [1] = { r = 1, g = 1, b = 1 }, [2] = { r = 1, g = 1, b = 1 }, [16] = { r = 1, g = 1, b = 1 } },
      },
      drawTextWithPalette = function() end,
    },
  })
  local state = controller({ assets = assets.widgets })
  state:start()
  state:tick(40)
  confirm(state)
  state:tick(6 + 30)
  confirm(state)
  state:tick(26)
  confirm(state)
  local ballView = state:view()
  Assert.equal(ballView.revealWidget, "ball_open")
  ballView.revealWidget = "ball_open"
  ballView.revealFrameIndex = 1
  local layout = OakIntroLayout.compute(800, 600, ballView, {}, assets)
  renderer:draw({
    layout = layout,
    visual = "oak",
    visualFrameIndex = 1,
    primaryWidget = "oak",
    sceneBrightness = 0,
    revealBrightness = 0,
    revealOpacity = 1,
    revealWidget = "ball_open",
    revealFrameIndex = 1,
  })
  Assert.equal(graphics.draws[#graphics.draws - 0].image.path, "assets/generated/intro/ball-open-0.png")
  advanceUntilPhase(state, "marill_appear")
  local appearance = state:view()
  Assert.equal(appearance.revealWidget, "marill_appear")
  local appearanceLayout = OakIntroLayout.compute(800, 600, appearance, {}, assets)
  renderer:draw({
    layout = appearanceLayout,
    visual = "oak",
    visualFrameIndex = 1,
    primaryWidget = "oak",
    sceneBrightness = 0,
    revealBrightness = 0,
    revealOpacity = 1,
    revealWidget = appearance.revealWidget,
    revealFrameIndex = appearance.revealFrameIndex,
  })
  Assert.equal(graphics.draws[#graphics.draws].image.path, "assets/generated/intro/marill-appear.png")
  renderer:dispose()
end

function T.tests.profile_and_name_controls_share_explicit_draw_and_hit_rectangles()
  local state = controller()
  state:start()
  state:tick(40)
  confirm(state)
  state:tick(6 + 30)
  confirm(state)
  state:tick(26)
  confirm(state)
  advanceUntilPhase(state, "oak_live_alongside")
  confirm(state)
  advanceUntilPhase(state, "oak_tell_about_yourself")
  confirm(state)
  confirm(state)
  state:tick(26)
  Assert.equal(state:view().phase, "gender_select")
  local genderLayout = OakIntroLayout.compute(390, 844, state:view(), { "A", "B" }, manifest())
  Assert.notNil(genderLayout.genderButtons)
  confirm(state)
  confirm(state)
  confirm(state)
  confirm(state)
  advanceUntilPhase(state, "name_edit")
  Assert.equal(state:view().phase, "name_edit")
  local layout = OakIntroLayout.compute(390, 844, state:view(), { "A", "B" }, manifest())
  Assert.notNil(layout.nameKeys)
  Assert.equal(layout.nameKeys[1].label, "A")
end

-- Oak's in-progress slide displacement is the source-space offset times the
-- uniform source-canvas scale, with no host-space cap (stage percentage,
-- right-room clipping, etc.) shortening it.
T.tests.oak_motion_uses_source_offset_times_uniform_canvas_scale = function()
  local state = controller()
  state:start()
  state:tick(40)
  confirm(state)
  state:tick(6 + 30)
  confirm(state)
  local before = state:view()
  local beforeLayout = OakIntroLayout.compute(390, 844, before, { "A", "B" }, manifest())

  state:tick(13)
  local during = state:view()
  local duringLayout = OakIntroLayout.compute(390, 844, during, { "A", "B" }, manifest())
  local expected = -during.oakBgScrollX * duringLayout.subject.scale
  local beforeCenter = beforeLayout.subject.x + beforeLayout.subject.width / 2
  local duringCenter = duringLayout.subject.x + duringLayout.subject.width / 2
  Assert.near(duringCenter - beforeCenter, expected)
end

T.tests.ball_reveal_channels_preserve_independent_animation_timing = function()
  local assets = {
    oak = { frames = { { duration = 1 }, { duration = 1 }, { duration = 1 } } },
    marill = { frames = { { duration = 2 }, { duration = 3 } } },
    marill_appear = { frames = { { duration = 1 } } },
    ball_open = {
      frames = { { duration = 4 }, { duration = 1 }, { duration = 1 }, { duration = 1 }, { duration = 1 } },
    },
  }
  local state = controller({ assets = assets })
  state:start()
  state:tick(40)
  confirm(state)
  state:tick(6 + 30)
  confirm(state)
  state:tick(26)
  confirm(state)
  advanceUntilPhase(state, "marill_cry_wait")
  local initial = state:view()
  Assert.equal(initial.phase, "marill_cry_wait")
  Assert.equal(initial.primaryWidget, "oak")
  Assert.equal(initial.revealWidget, "marill")
  Assert.equal(initial.revealFrameIndex, 1)
  state:tick(1)
  local next = state:view()
  Assert.equal(next.visualFrameIndex, initial.visualFrameIndex)
  Assert.equal(next.revealFrameIndex, 2)
  state:tick(1)
  Assert.equal(state:view().revealFrameIndex, 2)
end

T.tests.name_controls_use_generated_text_and_shared_hit_rectangles = function()
  local graphics = FakeGraphics.new()
  local textCalls = {}
  local text = {
    drawText = function(_, value, x, y)
      textCalls[#textCalls + 1] = { value = value, x = x, y = y }
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function()
      return graphics.newImage()
    end,
    text = text,
    choiceText = {
      fontDef = {
        lineHeight = 16,
        palette = (function()
          local palette = {}
          for slot = 1, 16 do
            palette[slot] = { r = 1, g = 1, b = 1 }
          end
          return palette
        end)(),
      },
      drawTextWithPalette = function() end,
    },
  })
  local state = controller()
  local host = { setTextInput = function() end }
  local intro = OakIntroState.new({
    controller = state,
    manifest = manifest(),
    ---@diagnostic disable-next-line: assign-type-mismatch
    renderer = renderer,
    textRenderer = text,
    choiceText = renderer.choiceText,
    glyphs = { "A", "B" },
    width = 390,
    height = 844,
    textInputHost = host,
  })
  advanceToNameEdit(intro)
  Assert.equal(intro:view().phase, "name_edit")
  intro:textinput("A")
  local view = intro:view()
  local preview = assert(view.layout.namePreview)
  renderer:draw(view)
  local nameDraw = assert(textCalls[#textCalls - #view.layout.nameKeys])
  Assert.isTrue(nameDraw.x >= preview.x and nameDraw.x + text:textWidth(nameDraw.value) <= preview.x + preview.width)
  local focused = view.layout.nameKeys[view.virtualGlyphFocus].rect
  local focusedLines = 0
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "line" and rectangle.x == focused.x and rectangle.y == focused.y then
      focusedLines = focusedLines + 1
    end
  end
  Assert.equal(focusedLines, 1)
  intro:mousepressed(focused.x + focused.width / 2, focused.y + focused.height / 2, 1)
  Assert.equal(intro:view().name, "AA")
  intro:dispose()
end

T.tests.name_confirmation_draw_does_not_require_editor_preview_geometry = function()
  local graphics = FakeGraphics.new()
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = {
      fontDef = { lineHeight = 16 },
      drawText = function() end,
      textWidth = function(_, value)
        return #value * 8
      end,
    },
    choiceText = {
      fontDef = {
        lineHeight = 16,
        palette = (function()
          local palette = {}
          for slot = 1, 16 do
            palette[slot] = { r = 1, g = 1, b = 1 }
          end
          return palette
        end)(),
      },
      drawTextWithPalette = function() end,
    },
  })
  local intro = OakIntroState.new({
    controller = controller(),
    manifest = manifest(),
    ---@diagnostic disable-next-line: assign-type-mismatch
    renderer = renderer,
    textRenderer = renderer.text,
    choiceText = renderer.choiceText,
    glyphs = { "A", "B" },
    width = 390,
    height = 844,
    textInputHost = { setTextInput = function() end },
  })

  advanceToNameEdit(intro)
  Assert.equal(intro:view().phase, "name_edit")
  intro:textinput("A")
  -- Navigate keyboard focus onto the virtual Confirm key before
  -- activating it, matching the one confirm-capable-device contract.
  intro:keypressed("left")
  intro:keypressed("return")
  intro:tick(26)
  local view = intro:view()
  Assert.equal(view.phase, "name_confirm")
  Assert.isNil(view.layout.namePreview)
  renderer:draw(view)
  Assert.isTrue(#graphics.draws > 0)

  intro:dispose()
end

return T
