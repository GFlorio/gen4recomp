local Assert = require("tests.support.Assert")
local OakIntroLayout = require("game.src.game.OakIntroLayout")

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
    sourceReference = { width = sourceWidth, height = 192 },
    background = { width = sourceWidth, height = 192, sampling = "linear" },
    widgets = {
      oak = widget(80, 100, { x = 20, y = 100 }, { x = 20, y = 30, width = 80, height = 100 }),
      ball_open = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      marill = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      gender_background = widget(256, 192, { x = 128, y = 192 }, { x = 0, y = 0, width = 256, height = 192 }),
      gender_male = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      gender_female = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
    },
  }
  data.widgets.ball_open.sourceCenter = { x = 160, y = 80 }
  data.widgets.marill.sourceCenter = { x = 160, y = 80 }
  data.widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  data.widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  return data
end

local function manifest()
  return manifestWithWidth(256)
end

local function ordinaryView(offset)
  return {
    phase = "oak_world_inhabited",
    visual = "oak",
    primaryWidget = "oak",
    revealWidget = "ball_open",
    oakSlideOffset = offset,
  }
end

local function point(region, anchor)
  return {
    x = region.x + anchor.x * region.scale,
    y = region.y + anchor.y * region.scale,
  }
end

local function inside(inner, outer)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

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
    local oakPoint = point(centered.subject, data.widgets.oak.anchor)
    Assert.near(oakPoint.x, scene.x + 40 / 256 * scene.width)
    Assert.near(oakPoint.y, scene.y + 130 / 192 * scene.height)
    local revealPoint = point(centered.reveal, data.widgets.ball_open.anchor)
    local canvasScale = math.min(scene.width / 256, scene.height / 192)
    local canvasOriginX = scene.x + (scene.width - 256 * canvasScale) / 2
    local canvasOriginY = scene.y + (scene.height - 192 * canvasScale) / 2
    Assert.near(revealPoint.x, canvasOriginX + 160 * canvasScale, 1e-6)
    Assert.near(revealPoint.y, canvasOriginY + 80 * canvasScale, 1e-6)
    local expectedDisplacement = 52 / data.sourceReference.width * scene.width
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
      Assert.isTrue(x >= previousX, "slide progress toward -52 must not move host X left")
      previousX = x
    end
    local fullyShiftedX = previousX
    Assert.isTrue(fullyShiftedX > baseX, "the fully slid subject must be to the right of the base position")

    previousX = fullyShiftedX
    for _, offset in ipairs({ -40, -30, -20, -10, 0 }) do
      local layout = OakIntroLayout.compute(size[1], size[2], ordinaryView(offset), {}, data)
      local x = point(layout.subject, data.widgets.oak.anchor).x
      Assert.isTrue(x <= previousX, "the return slide must not move host X right")
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
  Assert.near(oakPoint.x / layout.scene.width, 40 / 256, 1e-9)
  local canvasScale = math.min(layout.scene.width / 256, layout.scene.height / 192)
  local canvasOriginX = layout.scene.x + (layout.scene.width - 256 * canvasScale) / 2
  Assert.near((revealPoint.x - canvasOriginX) / canvasScale, 160, 1e-9)
end

function T.tests.gender_selection_is_a_single_source_aligned_composition()
  local data = manifest()
  for _, size in ipairs({ { 1920, 1080 }, { 390, 844 } }) do
    local layout = OakIntroLayout.compute(size[1], size[2], {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      oakSlideOffset = 0,
    }, {}, data)
    Assert.deepEqual(layout.viewport, { x = 0, y = 0, width = size[1], height = size[2] })
    Assert.isTrue(inside(layout.oakRegion, layout.viewport))
    Assert.isTrue(inside(layout.selectorRegion, layout.viewport))
    Assert.isTrue(disjoint(layout.oakRegion, layout.selectorRegion))
    Assert.near(layout.selectorPanel.width / layout.selectorPanel.height, 4 / 3)
    Assert.isTrue(inside(layout.genderBackground, layout.selectorPanel))
    for gender, sourceX in pairs({ [0] = 64, [1] = 192 }) do
      local id = gender == 0 and "gender_male" or "gender_female"
      local choice = layout.genderChoices[gender]
      local choicePoint = point(choice, data.widgets[id].anchor)
      Assert.near(choicePoint.x, layout.selectorPanel.x + sourceX / 256 * layout.selectorPanel.width)
      Assert.near(choicePoint.y, layout.selectorPanel.y + 104 / 192 * layout.selectorPanel.height)
      Assert.deepEqual(layout.genderHitRegions[gender], choice)
    end
  end
end

function T.tests.slide_displacement_uses_manifest_reference_width_not_hardcoded_256()
  local data = manifestWithWidth(512)
  local scene = OakIntroLayout.compute(1024, 768, ordinaryView(0), {}, data).scene
  local centered = OakIntroLayout.compute(1024, 768, ordinaryView(0), {}, data)
  local shifted = OakIntroLayout.compute(1024, 768, ordinaryView(-52), {}, data)
  local expected = 52 / 512 * scene.width
  Assert.near(
    point(shifted.subject, data.widgets.oak.anchor).x - point(centered.subject, data.widgets.oak.anchor).x,
    expected,
    1e-6
  )
end

return T
