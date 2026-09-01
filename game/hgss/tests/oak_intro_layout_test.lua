local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")

local T = { tests = {} }

local function widget(width, height, anchor, sourceBounds)
  return {
    width = width,
    height = height,
    anchor = anchor,
    sourceBounds = sourceBounds,
    frames = {
      { width = width, height = height, duration = 1, anchor = anchor },
    },
  }
end

local function manifestWithWidth(sourceWidth)
  local data = {
    schemaVersion = 8,
    variant = "heartgold",
    sourceReference = { width = sourceWidth, height = 192 },
    background = { width = sourceWidth, height = 192, sampling = "linear" },
    widgets = {
      oak = widget(80, 100, { x = 20, y = 100 }, { x = 20, y = 30, width = 80, height = 100 }),
      male = widget(96, 120, { x = 24, y = 110 }, { x = 36, y = 24, width = 96, height = 120 }),
      female = widget(88, 116, { x = 22, y = 108 }, { x = 48, y = 28, width = 88, height = 116 }),
      ball_open = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      marill = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      gender_male = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      gender_female = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
    },
  }
  data.widgets.ball_open.sourceCenter = { x = 160, y = 80 }
  data.widgets.marill.sourceCenter = { x = 160, y = 80 }
  data.widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  data.widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  data.genderSelector = {
    defaultTone = { r = 100, g = 101, b = 102 },
    buttons = {
      male = {
        bounds = { x = 18, y = 25, width = 93, height = 148 },
        hitBounds = { x = 18, y = 25, width = 93, height = 148 },
      },
      female = {
        bounds = { x = 144, y = 25, width = 95, height = 148 },
        hitBounds = { x = 144, y = 25, width = 95, height = 148 },
      },
    },
  }
  data.profileConfirmation = {
    buttons = {
      male = {
        yes = {
          bounds = { x = 138, y = 26, width = 115, height = 57 },
          textBounds = { x = 136, y = 48, width = 104, height = 24 },
        },
        no = {
          bounds = { x = 138, y = 108, width = 115, height = 56 },
          textBounds = { x = 136, y = 128, width = 104, height = 24 },
        },
      },
      female = {
        yes = {
          bounds = { x = 10, y = 26, width = 115, height = 57 },
          textBounds = { x = 16, y = 48, width = 104, height = 24 },
        },
        no = {
          bounds = { x = 10, y = 108, width = 115, height = 56 },
          textBounds = { x = 16, y = 128, width = 104, height = 24 },
        },
      },
    },
  }
  return data
end

local function manifest()
  return manifestWithWidth(256)
end

local function profileManifest()
  local data = manifest()
  data.widgets.male = widget(96, 120, { x = 24, y = 110 }, { x = 36, y = 24, width = 96, height = 120 })
  data.widgets.female = widget(88, 116, { x = 22, y = 108 }, { x = 48, y = 28, width = 88, height = 116 })
  data.widgets.shrink_male = widget(44, 68, { x = 12, y = 62 }, { x = 142, y = 70, width = 44, height = 68 })
  data.widgets.shrink_female = widget(40, 64, { x = 11, y = 58 }, { x = 150, y = 72, width = 40, height = 64 })
  return data
end

local function ordinaryView(sourceBgScrollX)
  return {
    phase = "oak_world_inhabited",
    visual = "oak",
    primaryWidget = "oak",
    revealWidget = "ball_open",
    oakBgScrollX = sourceBgScrollX,
  }
end

local function compositionView(progress, phase)
  return {
    phase = phase or "gender_composition_transition",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = progress,
    oakBgScrollX = 0,
  }
end

---@param region { x: number, y: number, scale: number }
---@param anchor { x: number, y: number }
---@return { x: number, y: number }
local function point(region, anchor)
  return {
    x = region.x + anchor.x * region.scale,
    y = region.y + anchor.y * region.scale,
  }
end

---@param inner OakIntroStateRectangle
---@param outer OakIntroStateRectangle
---@return boolean
local function inside(inner, outer)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

---@param first OakIntroStateRectangle
---@param second OakIntroStateRectangle
---@return boolean
local function disjoint(first, second)
  return first.x + first.width <= second.x
    or second.x + second.width <= first.x
    or first.y + first.height <= second.y
    or second.y + second.height <= first.y
end

function T.tests.source_points_and_slide_direction_survive_responsive_hosts()
  local data = manifest()
  for _, size in ipairs({ { 1024, 768 }, { 1920, 1080 }, { 390, 844 } }) do
    local centered = OakIntroLayout.compute(size[1], size[2], ordinaryView(0), {}, data)
    local shifted = OakIntroLayout.compute(size[1], size[2], ordinaryView(-52), {}, data)
    local scene = assert(centered.scene)
    local canvasScale = math.min(scene.width / 256, scene.height / 192)
    local canvasOriginX = scene.x + (scene.width - 256 * canvasScale) / 2
    local canvasOriginY = scene.y + (scene.height - 192 * canvasScale) / 2
    local oakPoint = point(centered.subject, data.widgets.oak.anchor)
    Assert.near(oakPoint.x, canvasOriginX + 40 * canvasScale, 1e-6)
    Assert.near(oakPoint.y, canvasOriginY + 130 * canvasScale, 1e-6)
    local revealPoint = point(centered.reveal, data.widgets.ball_open.anchor)
    Assert.near(revealPoint.x, canvasOriginX + 160 * canvasScale, 1e-6)
    Assert.near(revealPoint.y, canvasOriginY + 80 * canvasScale, 1e-6)
    local expectedDisplacement = 52 * canvasScale
    Assert.near(point(shifted.subject, data.widgets.oak.anchor).x - oakPoint.x, expectedDisplacement, 1e-6)
    Assert.equal(centered.subject.scale, shifted.subject.scale)
    local shiftedRevealPoint = point(shifted.reveal, data.widgets.ball_open.anchor)
    Assert.near(shiftedRevealPoint.x, revealPoint.x, 1e-6)
    Assert.near(shiftedRevealPoint.y, revealPoint.y, 1e-6)
    Assert.isTrue(inside(centered.subject, scene))
    Assert.isTrue(inside(centered.reveal, scene))
  end
end

function T.tests.slide_progress_is_monotonic_right_then_monotonic_left()
  local data = manifest()
  for _, size in ipairs({ { 1024, 768 }, { 390, 844 } }) do
    local baseX =
      point(OakIntroLayout.compute(size[1], size[2], ordinaryView(0), {}, data).subject, data.widgets.oak.anchor).x
    local previousX = baseX
    for _, offset in ipairs({ -10, -20, -30, -40, -52 }) do
      local layout = OakIntroLayout.compute(size[1], size[2], ordinaryView(offset), {}, data)
      local x = point(layout.subject, data.widgets.oak.anchor).x
      Assert.isTrue(x >= previousX, "source scroll toward -52 must move host X right")
      previousX = x
    end
    local fullyShiftedX = previousX
    Assert.isTrue(fullyShiftedX > baseX, "the fully scrolled subject must be to the right of the base position")

    previousX = fullyShiftedX
    for _, offset in ipairs({ -40, -30, -20, -10, 0 }) do
      local layout = OakIntroLayout.compute(size[1], size[2], ordinaryView(offset), {}, data)
      local x = point(layout.subject, data.widgets.oak.anchor).x
      Assert.isTrue(x <= previousX, "the return scroll must move host X left")
      previousX = x
    end
    Assert.near(previousX, baseX, 1e-6)
    -- Slide does not affect scale, reveal geometry, or scene geometry
    local slideLayout = OakIntroLayout.compute(size[1], size[2], ordinaryView(-30), {}, data)
    local baseLayout = OakIntroLayout.compute(size[1], size[2], ordinaryView(0), {}, data)
    Assert.equal(slideLayout.subject.scale, baseLayout.subject.scale)
    Assert.deepEqual(slideLayout.reveal, baseLayout.reveal)
    Assert.deepEqual(slideLayout.scene, baseLayout.scene)
  end
end

function T.tests.tall_host_keeps_source_order_and_all_layout_rectangles_inside_viewport()
  local data = manifest()
  local layout = OakIntroLayout.compute(803, 992, ordinaryView(0), {}, data)
  Assert.deepEqual(layout.viewport, { x = 0, y = 0, width = 803, height = 992 })
  Assert.isTrue(inside(layout.subject, layout.viewport))
  Assert.isTrue(inside(layout.reveal, layout.viewport))
  Assert.isTrue(inside(layout.dialogue.outerRect, layout.viewport))
  local oakPoint = point(layout.subject, data.widgets.oak.anchor)
  local revealPoint = point(layout.reveal, data.widgets.ball_open.anchor)
  Assert.isTrue(oakPoint.x < revealPoint.x)
  local canvasScale = math.min(layout.scene.width / 256, layout.scene.height / 192)
  local canvasOriginX = layout.scene.x + (layout.scene.width - 256 * canvasScale) / 2
  Assert.near((oakPoint.x - canvasOriginX) / canvasScale, 40, 1e-9)
  Assert.near((revealPoint.x - canvasOriginX) / canvasScale, 160, 1e-9)
end

function T.tests.gender_selection_maps_source_geometry_and_centers_portraits()
  local data = manifest()
  for _, size in ipairs({ { 1920, 1080 }, { 390, 844 } }) do
    local layout = OakIntroLayout.compute(size[1], size[2], {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    Assert.deepEqual(layout.viewport, { x = 0, y = 0, width = size[1], height = size[2] })
    Assert.isTrue(inside(layout.oakRegion, layout.viewport))
    Assert.isTrue(inside(layout.selectorRegion, layout.viewport))
    Assert.isTrue(disjoint(layout.oakRegion, layout.selectorRegion))
    local canvas = assert(layout.genderCanvas)
    for gender = 0, 1 do
      local id = gender == 0 and "gender_male" or "gender_female"
      local item = assert(layout.genderButtons[gender])
      local button = item.button
      local source = data.genderSelector.buttons[gender == 0 and "male" or "female"].bounds
      Assert.near((button.rect.x - canvas.origin.x) / canvas.scale, source.x)
      Assert.near((button.rect.y - canvas.origin.y) / canvas.scale, source.y)
      Assert.near(button.rect.width / canvas.scale, source.width)
      Assert.near(button.rect.height / canvas.scale, source.height)

      local portrait = item.portraitRect
      local widgetValue = data.widgets[id]
      local center = widgetValue.sourceCenter
      Assert.near((portrait.x + widgetValue.anchor.x * canvas.scale - canvas.origin.x) / canvas.scale, center.x)
      Assert.near((portrait.y + widgetValue.anchor.y * canvas.scale - canvas.origin.y) / canvas.scale, center.y)
      Assert.near(portrait.width / canvas.scale, widgetValue.width)
      Assert.near(portrait.height / canvas.scale, widgetValue.height)
    end
    Assert.isTrue(disjoint(layout.genderButtons[0].button.rect, layout.genderButtons[1].button.rect))
  end
end

function T.tests.gender_confirmation_maps_selected_card_and_source_side_choices()
  local data = manifest()
  for selected, gender in pairs({ [0] = "male", [1] = "female" }) do
    local layout = OakIntroLayout.compute(800, 600, {
      phase = "gender_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = selected,
      genderCompositionProgress = 1,
      confirmationChoice = { kind = "gender", selected = 0 },
    }, {}, data)
    local canvas = assert(layout.genderCanvas)
    local profile = assert(layout.selectedProfileButton)
    local profileSource = data.genderSelector.buttons[gender].bounds
    Assert.equal(profile.key, gender)
    Assert.near((profile.button.rect.x - canvas.origin.x) / canvas.scale, profileSource.x)
    Assert.near((profile.button.rect.y - canvas.origin.y) / canvas.scale, profileSource.y)

    local choices = assert(layout.confirmationButtons)
    local sourceChoices = data.profileConfirmation.buttons[gender]
    for choice, key in pairs({ [0] = "yes", [1] = "no" }) do
      local entry = assert(choices[choice])
      local source = sourceChoices[key]
      Assert.equal(entry.key, key)
      Assert.near((entry.button.rect.x - canvas.origin.x) / canvas.scale, source.bounds.x)
      Assert.near((entry.button.rect.y - canvas.origin.y) / canvas.scale, source.bounds.y)
      Assert.near(entry.button.rect.width / canvas.scale, source.bounds.width)
      Assert.near(entry.button.rect.height / canvas.scale, source.bounds.height)
      Assert.near((entry.textRect.x - canvas.origin.x) / canvas.scale, source.textBounds.x)
      Assert.near((entry.textRect.y - canvas.origin.y) / canvas.scale, source.textBounds.y)
      Assert.near(entry.textRect.width / canvas.scale, source.textBounds.width)
      Assert.near(entry.textRect.height / canvas.scale, source.textBounds.height)
      Assert.equal(entry.textScale, canvas.scale)
    end
  end
end

function T.tests.name_confirmation_preserves_source_choice_group_in_ordinary_scene()
  local data = manifest()
  for _, gender in ipairs({ "male", "female" }) do
    local layout = OakIntroLayout.compute(800, 600, {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = gender == "male" and 0 or 1,
      confirmationChoice = { kind = "name", selected = 0 },
      genderCompositionProgress = 0,
      oakBgScrollX = 0,
    }, {}, data)

    Assert.isNil(layout.oakRegion)
    Assert.isNil(layout.selectorRegion)
    local choices = assert(layout.confirmationButtons)
    local scale = assert(layout.confirmationScale)
    local sourceChoices = data.profileConfirmation.buttons[gender]
    local previousBottom
    for choice, key in pairs({ [0] = "yes", [1] = "no" }) do
      local entry = assert(choices[choice])
      local source = sourceChoices[key]
      Assert.equal(entry.key, key)
      Assert.near(entry.button.rect.width / scale, source.bounds.width)
      Assert.near(entry.button.rect.height / scale, source.bounds.height)
      Assert.near(entry.textRect.width / scale, source.textBounds.width)
      Assert.near(entry.textRect.height / scale, source.textBounds.height)
      Assert.near(entry.textScale, scale)
      Assert.isTrue(inside(entry.button.rect, layout.stageContent))
      if previousBottom then
        Assert.near((entry.button.rect.y - previousBottom) / scale, 25)
      end
      previousBottom = entry.button.rect.y + entry.button.rect.height
    end
  end
end

function T.tests.gender_composition_interpolates_oak_into_the_contained_region()
  local data = manifest()
  local start = OakIntroLayout.compute(1920, 1080, compositionView(0), {}, data)
  local middle = OakIntroLayout.compute(1920, 1080, compositionView(0.5), {}, data)
  local final = OakIntroLayout.compute(1920, 1080, compositionView(1, "gender_select"), {}, data)

  Assert.isTrue(inside(final.subject, final.oakRegion))
  Assert.isTrue(disjoint(final.oakRegion, final.selectorRegion))
  Assert.near(middle.subject.x, (start.subject.x + final.subject.x) / 2)
  Assert.near(middle.subject.y, (start.subject.y + final.subject.y) / 2)
  Assert.near(middle.subject.scale, (start.subject.scale + final.subject.scale) / 2)
  Assert.near(middle.subject.width, data.widgets.oak.width * middle.subject.scale)
  Assert.near(middle.subject.height, data.widgets.oak.height * middle.subject.scale)
end

function T.tests.gender_composition_uniformly_shrinks_oak_when_the_region_is_small()
  local data = manifest()
  data.widgets.oak.width = 400
  data.widgets.oak.height = 500
  local start = OakIntroLayout.compute(390, 844, compositionView(0), {}, data)
  local final = OakIntroLayout.compute(390, 844, compositionView(1, "gender_select"), {}, data)

  Assert.isTrue(final.subject.scale < start.subject.scale)
  Assert.near(final.subject.width, data.widgets.oak.width * final.subject.scale)
  Assert.near(final.subject.height, data.widgets.oak.height * final.subject.scale)
  Assert.isTrue(inside(final.subject, final.oakRegion))
end

-- Full source scroll must inverse-transform to exactly the pinned -52 source
-- pixels under the uniform source-canvas scale, on every viewport shape --
-- not merely ones where the safe frame happens to be 4:3.
function T.tests.full_slide_inverse_transforms_to_exactly_fifty_two_source_pixels_on_every_viewport()
  local data = manifest()
  for _, size in ipairs({ { 390, 844 }, { 800, 600 }, { 1920, 1080 }, { 2560, 1080 } }) do
    local w, h = size[1], size[2]
    local atZero = OakIntroLayout.compute(w, h, ordinaryView(0), {}, data)
    local atFull = OakIntroLayout.compute(w, h, ordinaryView(-52), {}, data)
    local xZero = point(atZero.subject, data.widgets.oak.anchor).x
    local xFull = point(atFull.subject, data.widgets.oak.anchor).x
    local canvasScale = math.min(atZero.scene.width / 256, atZero.scene.height / 192)
    Assert.near(
      (xFull - xZero) / canvasScale,
      52,
      1e-6,
      "visible Oak displacement must equal +52 source pixels at " .. w .. "x" .. h
    )
    Assert.equal(atZero.subject.y, atFull.subject.y, "slide must not move Oak vertically")
    Assert.equal(atZero.subject.scale, atFull.subject.scale, "slide must not rescale Oak")
  end
end

function T.tests.slide_displacement_uses_manifest_reference_width_not_hardcoded_256()
  local data = manifestWithWidth(512)
  local scene = OakIntroLayout.compute(1024, 768, ordinaryView(0), {}, data).scene
  local centered = OakIntroLayout.compute(1024, 768, ordinaryView(0), {}, data)
  local shifted = OakIntroLayout.compute(1024, 768, ordinaryView(-52), {}, data)
  local canvasScale = math.min(scene.width / 512, scene.height / 192)
  local expected = 52 * canvasScale
  Assert.near(
    point(shifted.subject, data.widgets.oak.anchor).x - point(centered.subject, data.widgets.oak.anchor).x,
    expected,
    1e-6
  )
end

local function layoutSequenceCandidate()
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-oak-layout"
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

local function layoutSequenceAudio()
  return {
    playMusic = function() end,
    stopMusic = function() end,
    fadeMusicOut = function() end,
    play = function() end,
    playCry = function() end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function layoutSequenceController()
  return OakIntroController.new({
    candidate = layoutSequenceCandidate(),
    clock = {
      nowLocal = function()
        return { year = 2009, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
    audio = layoutSequenceAudio() --[[@as GameSound]],
    messages = {
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
    assets = {
      marill = { frames = { { duration = 1 } } },
      marill_appear = { frames = { { duration = 1 } } },
      ball_open = { frames = { { duration = 1 } } },
    },
    virtualGlyphs = { "A", "B", "G", "O", "L" },
    playerDataContext = { charmap = { A = 1, B = 2, G = 3, O = 4, L = 5 }, frameIndexes = { [0] = true } },
    randomU32 = function()
      return 0x12345678
    end,
  })
end

local function advanceControllerUntilPhase(state, phase)
  for _ = 1, 2000 do
    if state:view().phase == phase then
      return
    end
    state:tick(1)
  end
  error("Oak layout sequence did not reach phase: " .. phase)
end

local function driveControllerToNameEdit(state)
  state:start()
  advanceControllerUntilPhase(state, "greeting")
  state:press("confirm")
  advanceControllerUntilPhase(state, "oak_welcome")
  state:press("confirm")
  advanceControllerUntilPhase(state, "oak_world_inhabited")
  state:press("confirm")
  advanceControllerUntilPhase(state, "oak_live_alongside")
  state:press("confirm")
  advanceControllerUntilPhase(state, "oak_tell_about_yourself")
  state:press("confirm")
  state:press("confirm")
  state:tick(26)
  state:press("confirm")
  state:press("confirm")
  state:press("confirm")
  advanceControllerUntilPhase(state, "name_edit")
end

-- Drives the real Oak controller through name submission and asserts that
-- the responsive layout follows the composition exit back to ordinary Oak
-- geometry: mid-exit geometry reflects the current (non-terminal) progress,
-- and resizing before the exit finishes still lands on the ordinary mapping
-- for the final viewport once progress reaches exactly zero.
function T.tests.ordinary_oak_geometry_resumes_after_the_profile_composition_exit_across_resize()
  local data = manifest()
  for _, size in ipairs({ { 1024, 768 }, { 390, 844 } }) do
    local state = layoutSequenceController()
    driveControllerToNameEdit(state)
    state:inputText("GOLD")
    state:press("submit")

    for _ = 1, 13 do
      state:tick(1)
    end
    local midView = state:view()
    Assert.isTrue(
      midView.genderCompositionProgress > 0 and midView.genderCompositionProgress < 1,
      "test setup requires the exit to still be mid-transition"
    )
    local midLayout = OakIntroLayout.compute(size[1], size[2], midView, {}, data)
    Assert.notNil(midLayout.subject)
    Assert.isTrue(inside(midLayout.subject, midLayout.viewport))

    state:tick(26 - 13)
    local finalView = state:view()
    Assert.equal(finalView.phase, "name_confirm")
    Assert.equal(finalView.genderCompositionProgress, 0)
    local finalLayout = OakIntroLayout.compute(size[1], size[2], finalView, {}, data)
    local ordinaryLayout = OakIntroLayout.compute(size[1], size[2], ordinaryView(finalView.oakBgScrollX), {}, data)
    Assert.deepEqual(finalLayout.subject, ordinaryLayout.subject)
    Assert.isNil(finalLayout.oakRegion, "ordinary Oak presentation must not retain a split composition region")
    Assert.isNil(finalLayout.selectorRegion, "ordinary Oak presentation must not retain a selector region")
  end
end

function T.tests.profile_widgets_use_their_manifest_source_geometry()
  local data = profileManifest()
  for _, id in ipairs({ "male", "female", "shrink_male", "shrink_female" }) do
    local value = data.widgets[id]
    local layout = OakIntroLayout.compute(800, 600, {
      phase = "final_full_art_hold",
      visual = id,
      primaryWidget = id,
      oakBgScrollX = 0,
    }, {}, data)
    local scale = layout.sourceCanvas.scale
    Assert.equal(layout.subject.width, value.width * scale)
    Assert.equal(layout.subject.height, value.height * scale)
    Assert.near(layout.subject.x, layout.sourceCanvas.origin.x + value.sourceBounds.x * scale, 1e-9)
    Assert.near(layout.subject.y, layout.sourceCanvas.origin.y + value.sourceBounds.y * scale, 1e-9)
  end
end

return T
