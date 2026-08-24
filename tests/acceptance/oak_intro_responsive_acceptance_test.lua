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
local OakIntroRenderer = require("game.src.game.OakIntroRenderer")
local OakIntroState = require("game.src.game.OakIntroState")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
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
  "gender_background",
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

local function display(id, x, y, width, height, role, touch)
  return {
    id = id,
    rect = { x = x, y = y, width = width, height = height },
    safeRect = { x = x, y = y, width = width, height = height },
    role = role,
    touch = touch,
  }
end

local manifest

local function genderView()
  return {
    phase = "gender_select",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    oakSlideOffset = 0,
  }
end

local function genderMetrics()
  local metrics = manifest().widgets
  metrics.gender_background = {
    width = 256,
    height = 192,
    anchor = { x = 128, y = 96 },
  }
  metrics.gender_male = {
    width = 64,
    height = 96,
    anchor = { x = 32, y = 96 },
  }
  metrics.gender_female = {
    width = 64,
    height = 96,
    anchor = { x = 32, y = 96 },
  }
  return metrics
end

local function assertInside(inner, outer, message)
  Assert.isTrue(inner.x >= outer.x, message .. " x start")
  Assert.isTrue(inner.y >= outer.y, message .. " y start")
  Assert.isTrue(inner.x + inner.width <= outer.x + outer.width, message .. " x end")
  Assert.isTrue(inner.y + inner.height <= outer.y + outer.height, message .. " y end")
end

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
    if id == "ball_open" or id == "marill_appear" or id == "marill" then
      widgets[id].sourceCenter = { x = 160, y = 80 }
    end
  end
  return {
    schemaVersion = 3,
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

local function assertFiniteInside(region, bounds)
  Assert.isTrue(region.x == region.x and region.y == region.y)
  Assert.isTrue(region.width > 0 and region.height > 0)
  Assert.isTrue(region.x >= bounds.x and region.y >= bounds.y)
  Assert.isTrue(region.x + region.width <= bounds.x + bounds.width)
  Assert.isTrue(region.y + region.height <= bounds.y + bounds.height)
end

function T.tests.host_native_layout_contract_across_representative_viewports()
  local checked = IntroAssetCache.validateManifest(manifest())
  Assert.isTrue(checked, "scenario requires a valid schema-3 semantic manifest")
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

function T.tests.physical_and_portrait_gender_selection_keep_surface_roles_separate()
  local view = genderView()
  local metrics = genderMetrics()
  local dual = ScreenTopology.dualDisplay(
    display("world", 0, 0, 512, 384, "world", false),
    display("auxiliary", 0, 384, 512, 384, "auxiliary", true)
  )
  ---@diagnostic disable-next-line: redundant-parameter
  local physical = OakIntroLayout.compute(512, 768, view, { "A" }, metrics, dual)
  Assert.notNil(physical.mainRegion, "physical topology exposes the main region")
  Assert.notNil(physical.auxiliaryRegion, "physical topology exposes the auxiliary region")
  Assert.notNil(physical.genderBackground, "physical topology places the selector background")
  Assert.notNil(physical.genderChoices, "physical topology places selector choices")
  assertDisjoint(physical.mainRegion, physical.auxiliaryRegion, "physical main and auxiliary regions overlap")
  assertInside(
    physical.genderBackground,
    physical.auxiliaryRegion,
    "physical selector background leaves auxiliary surface"
  )

  local portrait = OakIntroLayout.compute(390, 844, view, { "A" }, metrics)
  Assert.notNil(portrait.mainRegion, "portrait topology exposes the main region")
  Assert.notNil(portrait.auxiliaryRegion, "portrait topology exposes the auxiliary region")
  Assert.notNil(portrait.genderChoices, "portrait topology places selector choices")
  assertDisjoint(portrait.mainRegion, portrait.auxiliaryRegion, "portrait main and auxiliary regions overlap")
  assertInside(portrait.genderChoices[0], portrait.auxiliaryRegion, "portrait male choice leaves auxiliary region")
  assertInside(portrait.genderChoices[1], portrait.auxiliaryRegion, "portrait female choice leaves auxiliary region")
end

function T.tests.wide_gender_selection_is_side_by_side_and_hit_regions_are_rendered_regions()
  local view = genderView()
  local layout = OakIntroLayout.compute(1920, 1080, view, { "A" }, genderMetrics())
  Assert.notNil(layout.mainRegion, "wide layout exposes the main region")
  Assert.notNil(layout.auxiliaryRegion, "wide layout exposes the auxiliary region")
  Assert.notNil(layout.genderBackground, "wide layout places the selector background")
  Assert.notNil(layout.genderChoices, "wide layout places selector choices")
  Assert.isTrue(layout.mainRegion.x < layout.auxiliaryRegion.x, "wide layout keeps main content left of controls")
  assertDisjoint(layout.mainRegion, layout.auxiliaryRegion, "wide main and auxiliary regions overlap")
  assertInside(layout.genderBackground, layout.auxiliaryRegion, "wide selector background leaves auxiliary region")
  for gender = 0, 1 do
    assertInside(layout.genderChoices[gender], layout.auxiliaryRegion, "wide selector choice leaves auxiliary region")
  end
  Assert.notNil(layout.genderHitRegions, "pointer hit regions come from the selector placement")
  Assert.deepEqual(layout.genderHitRegions, layout.genderChoices, "pointer and renderer use one selector geometry")
end

function T.tests.constrained_gender_selection_keeps_both_controls_and_main_context_usable()
  local view = genderView()
  for _, size in ipairs({ { 320, 240 }, { 800, 600 } }) do
    local layout = OakIntroLayout.compute(size[1], size[2], view, { "A" }, genderMetrics())
    Assert.notNil(layout.mainRegion, "constrained layout exposes essential main context")
    Assert.notNil(layout.auxiliaryRegion, "constrained layout exposes selector controls")
    Assert.notNil(layout.genderBackground, "constrained layout places the selector background")
    Assert.notNil(layout.genderChoices, "constrained layout places both choices")
    assertInside(layout.mainRegion, layout.viewport, "constrained main context leaves viewport")
    assertInside(layout.auxiliaryRegion, layout.viewport, "constrained selector leaves viewport")
    assertInside(layout.genderChoices[0], layout.auxiliaryRegion, "constrained male choice leaves controls")
    assertInside(layout.genderChoices[1], layout.auxiliaryRegion, "constrained female choice leaves controls")
    assertDisjoint(layout.genderChoices[0], layout.genderChoices[1], "constrained gender choices overlap")
    Assert.notNil(layout.genderHitRegions, "constrained pointer mapping has rendered hit regions")
  end
end

function T.tests.dialogue_visibility_keeps_the_main_oak_stage_stable()
  local metrics = manifest().widgets
  for _, size in ipairs({ { 320, 240 }, { 390, 844 }, { 800, 600 }, { 1920, 1080 }, { 2560, 1080 } }) do
    local closed = {
      phase = "oak_slide_right",
      visual = "oak",
      primaryWidget = "oak",
      oakSlideOffset = 0,
    }
    local open = {
      phase = closed.phase,
      visual = closed.visual,
      primaryWidget = closed.primaryWidget,
      oakSlideOffset = closed.oakSlideOffset,
      dialogue = { message = "oak.welcome", messageKey = "oak.welcome" },
    }
    local closedLayout = OakIntroLayout.compute(size[1], size[2], closed, {}, metrics)
    local openLayout = OakIntroLayout.compute(size[1], size[2], open, {}, metrics)
    Assert.deepEqual(openLayout.stage, closedLayout.stage)
    Assert.near(openLayout.subject.scale, closedLayout.subject.scale)
    Assert.near(openLayout.subject.y + openLayout.subject.height, closedLayout.subject.y + closedLayout.subject.height)
  end
end

function T.tests.oak_slide_endpoint_remains_held_until_reverse_slide()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  local centered = OakIntroLayout.compute(800, 600, state:view(), {}, manifest().widgets).subject
  state:press("confirm")
  state:tick(26)
  local endpoint = OakIntroLayout.compute(800, 600, state:view(), {}, manifest().widgets).subject
  Assert.isTrue(endpoint.x < centered.x, "the completed first slide must be visibly shifted")
  state:press("confirm")
  state:tick(30 + 40)
  local held = OakIntroLayout.compute(800, 600, state:view(), {}, manifest().widgets).subject
  Assert.near(held.x, endpoint.x)
  Assert.near(held.y, endpoint.y)
  state:press("confirm")
  state:tick(30)
  local reverse = state:view()
  Assert.equal(reverse.phase, "oak_slide_left")
  local reverseStart = OakIntroLayout.compute(800, 600, reverse, {}, manifest().widgets).subject
  Assert.near(reverseStart.x, held.x)
  state:tick(1)
  local moved = OakIntroLayout.compute(800, 600, state:view(), {}, manifest().widgets).subject
  Assert.isTrue(moved.x > reverseStart.x, "reverse slide moves monotonically toward center")
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

function T.tests.ball_reveal_uses_source_timed_stages_and_single_sound()
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
  Assert.equal(state:view().revealWidget, "ball_open")
  state:tick(30)
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
  assets.widgets.marill_appear = assets.widgets.marill
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
      drawText = function() end,
      textWidth = function()
        return 0
      end,
    },
  })
  local state = controller({ assets = assets.widgets })
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  local ballView = state:view()
  Assert.equal(ballView.revealWidget, "ball_open")
  ballView.revealWidget = "ball_open"
  ballView.revealFrameIndex = 1
  local layout = OakIntroLayout.compute(800, 600, ballView, {}, assets.widgets)
  renderer:draw({
    layout = layout,
    visual = "oak",
    visualFrameIndex = 1,
    primaryWidget = "oak",
    flashAlpha = 0,
    revealWidget = "ball_open",
    revealFrameIndex = 1,
  })
  Assert.equal(graphics.draws[#graphics.draws - 0].image.path, "assets/generated/intro/ball-open-0.png")
  state:tick(30)
  local appearance = state:view()
  Assert.equal(appearance.revealWidget, "marill_appear")
  local appearanceLayout = OakIntroLayout.compute(800, 600, appearance, {}, assets.widgets)
  renderer:draw({
    layout = appearanceLayout,
    visual = "oak",
    visualFrameIndex = 1,
    primaryWidget = "oak",
    flashAlpha = 0,
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

T.tests.oak_motion_uses_normalized_progress_and_rendered_scale = function()
  local state = controller()
  state:start()
  state:tick(40)
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  local before = state:view()
  local beforeLayout = OakIntroLayout.compute(390, 844, before, { "A", "B" }, manifest().widgets)

  state:tick(13)
  local during = state:view()
  local duringLayout = OakIntroLayout.compute(390, 844, during, { "A", "B" }, manifest().widgets)
  local expected = math.min(52 * duringLayout.subject.scale, duringLayout.stageContent.width * 0.24)
    * (during.oakSlideOffset / -52)
  local beforeCenter = beforeLayout.subject.x + beforeLayout.subject.width / 2
  local duringCenter = duringLayout.subject.x + duringLayout.subject.width / 2
  Assert.near(beforeCenter - duringCenter, expected)
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
  state:press("confirm")
  state:tick(6 + 30)
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:tick(30)
  local initial = state:view()
  Assert.equal(initial.phase, "marill_cry_wait")
  Assert.equal(initial.primaryWidget, "oak")
  Assert.equal(initial.revealWidget, "marill")
  Assert.equal(initial.revealFrameIndex, 1)
  state:tick(1)
  local next = state:view()
  Assert.equal(next.visualFrameIndex, initial.visualFrameIndex)
  Assert.equal(next.revealFrameIndex, 1)
  Assert.equal(next.revealFrameIndex, 1)
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
  })
  local state = controller()
  local host = { setTextInput = function() end }
  local intro = OakIntroState.new({
    controller = state,
    manifest = manifest(),
    ---@diagnostic disable-next-line: assign-type-mismatch
    renderer = renderer,
    textRenderer = text,
    glyphs = { "A", "B" },
    width = 390,
    height = 844,
    textInputHost = host,
  })
  intro:tick(40)
  intro:keypressed("return")
  intro:tick(6 + 30)
  intro:keypressed("return")
  intro:tick(26)
  intro:keypressed("return")
  intro:tick(30 + 40)
  intro:keypressed("return")
  intro:tick(30 + 26)
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:tick(40)
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
      drawText = function() end,
      textWidth = function(_, value)
        return #value * 8
      end,
    },
  })
  local intro = OakIntroState.new({
    controller = controller(),
    manifest = manifest(),
    ---@diagnostic disable-next-line: assign-type-mismatch
    renderer = renderer,
    textRenderer = renderer.text,
    glyphs = { "A", "B" },
    width = 390,
    height = 844,
    textInputHost = { setTextInput = function() end },
  })

  intro:tick(40)
  intro:keypressed("return")
  intro:tick(6 + 30)
  intro:keypressed("return")
  intro:tick(26)
  intro:keypressed("return")
  intro:tick(30 + 40)
  intro:keypressed("return")
  intro:tick(30 + 26)
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:keypressed("return")
  intro:tick(40)
  Assert.equal(intro:view().phase, "name_edit")
  intro:textinput("A")
  intro:keypressed("return")
  local view = intro:view()
  Assert.equal(view.phase, "name_confirm")
  Assert.isNil(view.layout.namePreview)
  renderer:draw(view)
  Assert.isTrue(#graphics.draws > 0)

  intro:dispose()
end

return T
