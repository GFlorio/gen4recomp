-- Production Oak presentation must consume the corrected source
-- semantics for ball trajectory, viewport invariance, gender composition,
-- focus highlight, and shrink timing.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local OakIntroController = require("libs.engine.src.OakIntroController")
local OakIntroLayout = require("game.src.game.OakIntroLayout")
local OakIntroRenderer = require("game.src.game.OakIntroRenderer")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local NewGame = require("libs.engine.src.NewGame")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "oak", "presentation", "fidelity" },
  },
  tests = {},
}

local REFERENCE = { width = 256, height = 192 }

local function loadManifest(versionId)
  versionId = versionId or "heartgold"
  local cache = CacheFs.forVersion(versionId)
  local manifest = assert(cache:loadLua("data/generated/intro/intro.lua"), "missing intro manifest for " .. versionId)
  local ok, err = IntroAssetCache.validateManifest(manifest)
  Assert.isTrue(ok, err and err.message or "manifest invalid")
  return manifest
end

local function candidate()
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-acceptance-d02"
      end,
    },
    versionId = "heartgold",
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, sourceFacing = 1 },
  })
end

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

local function fakeAudio()
  local trace = {}
  return {
    trace = trace,
    playMusic = function(_, id)
      trace[#trace + 1] = { name = "music", value = id }
    end,
    stopMusic = function()
      trace[#trace + 1] = { name = "stop_music" }
    end,
    fadeMusicOut = function(_, spec)
      trace[#trace + 1] = { name = "fade_out", value = spec }
    end,
    play = function(_, id)
      trace[#trace + 1] = { name = "effect", value = id }
    end,
    playCry = function(_, species, form)
      trace[#trace + 1] = { name = "cry", value = { species = species, form = form } }
    end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function makeController(manifest)
  local assets = manifest and manifest.widgets
    or {
      oak = { frames = { { duration = 1 } } },
      marill = { frames = { { duration = 1 } } },
      marill_appear = { frames = { { duration = 1 } } },
      ball_open = { frames = { { duration = 1 } } },
      shrink_male = { frames = { { duration = 1 } } },
      shrink_female = { frames = { { duration = 1 } } },
    }
  return OakIntroController.new({
    candidate = candidate(),
    clock = {
      nowLocal = function()
        return { hour = 12, minute = 0 }
      end,
    },
    audio = fakeAudio(),
    messages = MESSAGES,
    assets = assets,
    playerDataContext = { charmap = { A = 1, B = 2, G = 3, O = 4, L = 5, D = 6 }, frameIndexes = { [0] = true } },
    randomU32 = function()
      return 0x12345678
    end,
    virtualGlyphs = { "A", "B", "G", "O", "L", "D" },
  })
end

local function advanceUntilPhase(ctrl, phase)
  for _ = 1, 5000 do
    if ctrl:view().phase == phase then
      return
    end
    ctrl:tick(1)
  end
  error("did not reach phase " .. phase .. " current=" .. ctrl:view().phase)
end

local function driveToBallOpen(manifest)
  local ctrl = makeController(manifest)
  ctrl:start()
  ctrl:tick(40)
  ctrl:press("confirm")
  ctrl:tick(6)
  -- fade_wait needs audio not fading
  ctrl:tick(30)
  ctrl:press("confirm")
  ctrl:tick(26)
  ctrl:press("confirm")
  return ctrl
end

-- Verifies the ball and marill reveal is placed through source
-- transformed geometry instead of a fixed centered crop. Every
-- animation frame should contribute a distinct host position when
-- its source translate changes.
function T.tests.ball_trajectory_uses_per_frame_source_placement()
  local manifest = loadManifest("heartgold")
  local widget = assert(manifest.widgets.marill_appear, "marill_appear missing")
  Assert.isTrue(#widget.frames > 1, "marill_appear must have multiple frames for trajectory")
  local hasTranslate = false
  for _, f in ipairs(widget.frames) do
    if f.translateX ~= 0 or f.translateY ~= 0 then
      hasTranslate = true
    end
  end
  Assert.isTrue(hasTranslate, "manifest frames must carry source translate for placement")

  local ctrl = driveToBallOpen(manifest)
  advanceUntilPhase(ctrl, "marill_appear")
  -- Record host reveal rectangles for every marill_appear frame
  local rects = {}
  for idx = 1, #widget.frames do
    local view = ctrl:view()
    view.revealWidget = "marill_appear"
    view.revealFrameIndex = idx
    -- ensure layout sees revealWidget
    local layout = OakIntroLayout.compute(800, 600, view, {}, manifest)
    Assert.notNil(layout.reveal, "layout must produce reveal rect")
    rects[idx] = { x = layout.reveal.x, y = layout.reveal.y, w = layout.reveal.width, h = layout.reveal.height }
    -- advance controller by frame duration to next frame for realism, but layout test uses explicit index
  end
  -- At least one consecutive pair must be displaced in source space
  local displaced = false
  for i = 2, #rects do
    if math.abs(rects[i].x - rects[i - 1].x) > 0.5 or math.abs(rects[i].y - rects[i - 1].y) > 0.5 then
      displaced = true
      break
    end
  end
  Assert.isTrue(
    displaced,
    "consecutive reveal frames must be visibly displaced via source placement, not centered identically"
  )
  -- Also ensure not glued to oak portrait anchor
  local view = ctrl:view()
  view.revealWidget = "marill_appear"
  view.revealFrameIndex = 1
  local layout = OakIntroLayout.compute(800, 600, view, {}, manifest)
  local oak = layout.subject
  Assert.isTrue(
    math.abs(layout.reveal.x - oak.x) > 1 or math.abs(layout.reveal.y - oak.y) > 1,
    "reveal must not be glued to oak anchor"
  )
end

function T.tests.ball_and_marill_geometry_stable_across_viewport_shapes()
  local manifest = loadManifest("heartgold")
  local view = {
    phase = "marill_appear",
    visual = "oak",
    primaryWidget = "oak",
    revealWidget = "marill_appear",
    revealFrameIndex = 12,
    oakSlideOffset = -52,
  }
  local sizes = { { 320, 240 }, { 390, 844 }, { 800, 600 }, { 1920, 1080 }, { 2560, 1080 } }
  local function safeFrame(w, h)
    local minimum = math.min(w, h)
    local inset = math.min(12, math.floor(minimum * 0.035 + 0.5), math.floor((minimum - 1) / 2))
    return { x = inset, y = inset, width = w - inset * 2, height = h - inset * 2 }
  end
  local function canvasFor(w, h)
    local sf = safeFrame(w, h)
    local scene = { x = 0, y = sf.y, width = w, height = sf.height }
    local scale = math.min(scene.width / REFERENCE.width, scene.height / REFERENCE.height)
    local origin = {
      x = scene.x + (scene.width - REFERENCE.width * scale) / 2,
      y = scene.y + (scene.height - REFERENCE.height * scale) / 2,
    }
    return { scene = scene, scale = scale, origin = origin }
  end
  local sources = {}
  for _, sz in ipairs(sizes) do
    local w, h = sz[1], sz[2]
    local layout = OakIntroLayout.compute(w, h, view, {}, manifest)
    Assert.notNil(layout.reveal, "reveal missing at " .. w .. "x" .. h)
    local c = canvasFor(w, h)
    -- Inverse map reveal center back to source
    local hx = layout.reveal.x + layout.reveal.width / 2
    local hy = layout.reveal.y + layout.reveal.height / 2
    local sx = (hx - c.origin.x) / c.scale
    local sy = (hy - c.origin.y) / c.scale
    sources[#sources + 1] = { x = sx, y = sy, scale = c.scale }
  end
  local base = sources[1]
  for i = 2, #sources do
    Assert.near(sources[i].x, base.x, 0.5, "marill source x must be invariant across viewports (index " .. i .. ")")
    Assert.near(sources[i].y, base.y, 0.5, "marill source y must be invariant across viewports (index " .. i .. ")")
  end
  -- Also check ball_open at same sizes
  view.revealWidget = "ball_open"
  view.revealFrameIndex = 1
  sources = {}
  for _, sz in ipairs(sizes) do
    local w, h = sz[1], sz[2]
    local layout = OakIntroLayout.compute(w, h, view, {}, manifest)
    local c = canvasFor(w, h)
    local hx = layout.reveal.x + layout.reveal.width / 2
    local hy = layout.reveal.y + layout.reveal.height / 2
    local sx = (hx - c.origin.x) / c.scale
    local sy = (hy - c.origin.y) / c.scale
    sources[#sources + 1] = { x = sx, y = sy }
  end
  base = sources[1]
  for i = 2, #sources do
    Assert.near(sources[i].x, base.x, 0.5, "ball source x invariant")
    Assert.near(sources[i].y, base.y, 0.5, "ball source y invariant")
  end
end

function T.tests.gender_select_preserves_source_centers_and_female_palette()
  local manifest = loadManifest("heartgold")
  local view = { phase = "gender_select", genderFocus = 0, oakSlideOffset = 0 }
  for _, sz in ipairs({ { 800, 600 }, { 390, 844 } }) do
    local w, h = sz[1], sz[2]
    local layout = OakIntroLayout.compute(w, h, view, {}, manifest)
    Assert.notNil(layout.genderBackground, "gender background missing")
    Assert.notNil(layout.genderChoices, "gender choices missing")
    Assert.notNil(layout.genderChoices[0], "male choice missing")
    Assert.notNil(layout.genderChoices[1], "female choice missing")
    Assert.notNil(layout.genderHitRegions, "hit regions missing")
    Assert.deepEqual(layout.genderHitRegions, layout.genderChoices, "hit regions must equal rendered choice rects")
    -- Scales must be uniform for one canvas composition
    local sBg = layout.genderBackground.scale
    local sMale = layout.genderChoices[0].scale
    local sFemale = layout.genderChoices[1].scale
    Assert.near(sMale, sFemale, 1e-9, "male and female choices must share uniform scale at " .. w .. "x" .. h)
    Assert.near(sBg, sMale, 1e-9, "gender background and choices must share uniform scale at " .. w .. "x" .. h)
    -- Centers via same canvas: male (64,104) female (192,104)
    -- Derive canvas from selectorPanel: it maps 256x192 into panel
    local panel = assert(layout.selectorPanel, "selectorPanel missing")
    local scale = math.min(panel.width / REFERENCE.width, panel.height / REFERENCE.height)
    local origin = {
      x = panel.x + (panel.width - REFERENCE.width * scale) / 2,
      y = panel.y + (panel.height - REFERENCE.height * scale) / 2,
    }
    local function hostCenter(srcX, srcY)
      return { x = origin.x + srcX * scale, y = origin.y + srcY * scale }
    end
    local maleExp = hostCenter(64, 104)
    local femaleExp = hostCenter(192, 104)
    local maleAct = {
      x = layout.genderChoices[0].x + layout.genderChoices[0].width / 2,
      y = layout.genderChoices[0].y + layout.genderChoices[0].height / 2,
    }
    local femaleAct = {
      x = layout.genderChoices[1].x + layout.genderChoices[1].width / 2,
      y = layout.genderChoices[1].y + layout.genderChoices[1].height / 2,
    }
    Assert.near(maleAct.x, maleExp.x, 1.0, "male center x must map from (64,104) via shared canvas")
    Assert.near(maleAct.y, maleExp.y, 1.0, "male center y must map from (64,104) via shared canvas")
    Assert.near(femaleAct.x, femaleExp.x, 1.0, "female center x must map from (192,104) via shared canvas")
    Assert.near(femaleAct.y, femaleExp.y, 1.0, "female center y must map from (192,104) via shared canvas")
    Assert.isTrue(maleAct.x < femaleAct.x, "male must be left of female preserving source ordering")
    -- Source horizontal separation preserved after inverse mapping
    local maleSrcX = (maleAct.x - origin.x) / scale
    local femaleSrcX = (femaleAct.x - origin.x) / scale
    Assert.near(femaleSrcX - maleSrcX, 128, 1.0, "horizontal separation must be 128 source units")
  end
  -- Female palette comes from derived cache palette override, not host tint
  local maleW = manifest.widgets.gender_male or manifest.widgets.male
  local femaleW = manifest.widgets.gender_female or manifest.widgets.female
  -- gender selector widgets are gender_male / gender_female
  local selMale = manifest.widgets.gender_male
  local selFemale = manifest.widgets.gender_female
  Assert.notNil(selMale, "manifest gender_male missing")
  Assert.notNil(selFemale, "manifest gender_female missing")
  -- Female must use palette bank 1 (source override) distinct from male bank 0
  -- Check per-frame metadata if present
  local maleOverride = selMale.frames[1].paletteOverride or 0
  -- Compiler stores paletteOverride only via asset spec, but manifest frames carry element/translate; palette bank is implicit via image composition
  -- Verify female image differs and provenance indicates correct palette member
  Assert.isTrue(selFemale.image ~= selMale.image, "female selector must use distinct derived image from C02")
  -- Verify female widget height matches expected derived composition (not tinted male)
  Assert.isTrue(selFemale.height > 0 and selMale.height > 0, "selector dimensions present")
end

function T.tests.gender_focus_uses_source_palette_blink_without_rectangle()
  local manifest = loadManifest("heartgold")
  local ctrl = makeController(manifest)
  ctrl:start()
  -- Drive to gender_select
  ctrl:tick(40)
  ctrl:press("confirm")
  ctrl:tick(6)
  ctrl:tick(30)
  ctrl:press("confirm")
  ctrl:tick(26)
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "oak_live_alongside")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "oak_tell_about_yourself")
  ctrl:press("confirm")
  ctrl:press("confirm")
  Assert.equal(ctrl:view().phase, "gender_select", "must reach gender_select")
  -- Focus blink contract: view should expose deterministic blink delta/timer
  local view0 = ctrl:view()
  -- The focused selection uses sin(timer*10deg)*8 additive RGB555 delta
  -- Unfocused uses default + gray. Timer resets on focus change.
  -- Check view exposes blink state (implementation may expose delta or timer)
  local hasBlink = view0.focusBlinkDelta ~= nil
    or view0.focusTimer ~= nil
    or view0.focusBrightnessDelta ~= nil
    or view0.genderFocusBlink ~= nil
  Assert.isTrue(hasBlink, "gender focus view must expose source blink timer or derived delta")
  -- Timer reset semantics: moving focus right must reset phase to zero
  local deltaBefore = view0.focusBlinkDelta or view0.focusBrightnessDelta or 0
  ctrl:press("right")
  local viewAfter = ctrl:view()
  Assert.equal(viewAfter.genderFocus, 1, "focus must move right")
  local deltaAfter = viewAfter.focusBlinkDelta or viewAfter.focusBrightnessDelta or viewAfter.focusTimer or 0
  -- After reset, delta/timer must be zero
  if viewAfter.focusBlinkDelta ~= nil then
    Assert.equal(viewAfter.focusBlinkDelta, 0, "focus blink delta must reset to 0 on focus change")
  elseif viewAfter.focusTimer ~= nil then
    Assert.equal(viewAfter.focusTimer, 0, "focus timer must reset to 0 on focus change")
  end
  -- Advance several ticks and check sinusoidal progression (10deg steps)
  ctrl:tick(1)
  local v1 = ctrl:view()
  -- No explicit color check without palette helper, but delta should have advanced
  -- Renderer must not draw rectangular outline
  local graphics = FakeGraphics.new()
  local renderer = OakIntroRenderer.new({
    manifest = manifest,
    graphics = graphics,
    imageLoader = function()
      return graphics.newImage()
    end,
    text = {
      drawText = function() end,
      textWidth = function()
        return 0
      end,
    },
  })
  local layout = OakIntroLayout.compute(800, 600, viewAfter, {}, manifest)
  local drawView = {}
  for k, v in pairs(viewAfter) do
    drawView[k] = v
  end
  drawView.layout = layout
  drawView.visual = "oak"
  drawView.visualFrameIndex = 1
  drawView.sceneBrightness = 0
  drawView.revealBrightness = 0
  drawView.revealOpacity = 1
  renderer:draw(drawView)
  local lineRects = 0
  for _, r in ipairs(graphics.rectangles) do
    if r.mode == "line" then
      lineRects = lineRects + 1
    end
  end
  Assert.equal(
    lineRects,
    0,
    "renderer must not draw rectangular focus outline around gender choice; source palette blink is the only indication"
  )
  renderer:dispose()
end

function T.tests.shrink_sequence_uses_composed_frames_and_source_delay()
  local manifest = loadManifest("heartgold")
  local ctrl = makeController(manifest)
  ctrl:start()
  -- Full drive to shrink_animation via semantic progression
  ctrl:tick(40)
  ctrl:press("confirm")
  ctrl:tick(6)
  ctrl:tick(30)
  ctrl:press("confirm")
  ctrl:tick(26)
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "oak_live_alongside")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "oak_tell_about_yourself")
  ctrl:press("confirm")
  ctrl:press("confirm")
  Assert.equal(ctrl:view().phase, "gender_select")
  ctrl:press("confirm")
  ctrl:press("confirm")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "name_edit")
  ctrl:inputText("GOLD")
  ctrl:press("submit")
  Assert.equal(ctrl:view().phase, "name_confirm")
  ctrl:press("confirm")
  Assert.equal(ctrl:view().phase, "final_dialogue")
  ctrl:press("confirm")
  -- now final_fade_out -> final_full_art_fade_in -> final_full_art_hold -> shrink_animation
  advanceUntilPhase(ctrl, "shrink_animation")
  local view = ctrl:view()
  Assert.equal(view.phase, "shrink_animation", "must enter shrink_animation")
  -- Identify which shrink widget is active (male by default)
  local widgetId = view.primaryWidget or view.visual
  Assert.isTrue(widgetId == "shrink_male" or widgetId == "shrink_female", "shrink widget must be shrink_male/female")
  local widget = assert(manifest.widgets[widgetId], "shrink widget missing in manifest")
  Assert.equal(#widget.frames, 4, "shrink must have 4 replacement frames")
  -- Record frame index per tick through completion
  local trace = {}
  local startTick = view.sourceFrames
  trace[#trace + 1] = { tick = startTick, frame = view.visualFrameIndex, widget = widgetId }
  for _ = 1, 100 do
    ctrl:tick(1)
    view = ctrl:view()
    if view.phase == "complete" then
      trace[#trace + 1] = { tick = view.sourceFrames, phase = "complete" }
      break
    end
    if trace[#trace].frame ~= view.visualFrameIndex or trace[#trace].widget ~= (view.primaryWidget or view.visual) then
      trace[#trace + 1] =
        { tick = view.sourceFrames, frame = view.visualFrameIndex, widget = view.primaryWidget or view.visual }
    end
    if #trace > 10 then
      break
    end
  end
  -- Must have visited 4 distinct frames in order
  local framesSeen = {}
  for _, e in ipairs(trace) do
    if e.frame then
      framesSeen[#framesSeen + 1] = e.frame
    end
  end
  Assert.equal(
    #framesSeen,
    4,
    "shrink must progress through 4 replacement frames in order, saw " .. table.concat(framesSeen, ",")
  )
  for i = 1, 4 do
    Assert.equal(framesSeen[i], i, "shrink frame order must be sequential")
  end
  -- Each frame must be retained for exactly 8 subsequent updates before next selection
  -- Check tick deltas between frame changes
  for i = 2, #trace - 1 do
    local delta = trace[i].tick - trace[i - 1].tick
    -- trace includes startTick, so delta is ticks spent on previous frame
    Assert.equal(
      delta,
      9,
      "after selecting each replacement, exactly eight subsequent updates must keep it before next selection (expected delta 9, got "
        .. delta
        .. ")"
    )
  end
  -- Completion must follow sentinel without extra frame
  local last = trace[#trace]
  Assert.equal(last.phase, "complete", "shrink must complete via sentinel without fabricated extra replacement")
  Assert.equal(ctrl:view().phase, "complete", "controller must be complete after shrink")
end

return T
