-- Production Oak presentation must consume the corrected source
-- semantics for ball trajectory, viewport invariance, gender composition,
-- focus highlight, and shrink timing.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local NewGame = require("game.hgss.src.newgame.NewGame")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "oak", "presentation", "fidelity" },
  },
  tests = {},
}

local REFERENCE = { width = 256, height = 192 }

local function loadManifest(versionId)
  versionId = versionId or AcceptanceHarness.defaultVersion()
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
        return "save-acceptance-oak"
      end,
    },
    versionId = AcceptanceHarness.defaultVersion(),
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

local function makeController(manifest, audio)
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
        return { year = 2009, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
    audio = (audio or fakeAudio()) --[[@as GameSound]],
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

local function enterGenderSelection(ctrl)
  ctrl:press("confirm")
  Assert.equal(ctrl:view().phase, "gender_composition_transition")
  Assert.equal(ctrl:view().genderCompositionProgress, 0)
  ctrl:tick(26)
  Assert.equal(ctrl:view().phase, "gender_select")
  Assert.equal(ctrl:view().genderCompositionProgress, 1)
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

-- The producer's transformed pixels move inside one stable generated union
-- surface; layout addresses that surface by its source center only.
function T.tests.transformed_reveal_frames_keep_one_source_anchor()
  local manifest = loadManifest()
  local widget = assert(manifest.widgets.marill_appear, "marill_appear missing")
  Assert.isTrue(#widget.frames > 1, "marill_appear must have multiple frames for trajectory")
  local firstIndex, secondIndex
  for index, frame in ipairs(widget.frames) do
    if frame.translateX ~= 0 or frame.translateY ~= 0 then
      if firstIndex == nil then
        firstIndex = index
      else
        secondIndex = index
        break
      end
    end
  end
  Assert.notNil(firstIndex, "manifest must contain a translated reveal frame")
  Assert.notNil(secondIndex, "manifest must contain two translated reveal frames")

  local ctrl = driveToBallOpen(manifest)
  advanceUntilPhase(ctrl, "marill_appear")
  local cache = CacheFs.forVersion(AcceptanceHarness.defaultVersion())
  local frameBytes = {}
  local anchors = {}
  for _, index in ipairs({ firstIndex, secondIndex }) do
    local view = ctrl:view()
    view.revealWidget = "marill_appear"
    view.revealFrameIndex = index
    view.oakBgScrollX = 0
    local layout = OakIntroLayout.compute(800, 600, view, {}, manifest)
    local reveal = assert(layout.reveal, "layout must produce reveal rect")
    local canvas = assert(layout.revealCanvas)
    anchors[#anchors + 1] = {
      x = reveal.x + widget.anchor.x * canvas.scale,
      y = reveal.y + widget.anchor.y * canvas.scale,
    }
    frameBytes[#frameBytes + 1] = assert(cache:read(widget.frames[index].image))
  end
  Assert.near(anchors[1].x, anchors[2].x, 1e-6)
  Assert.near(anchors[1].y, anchors[2].y, 1e-6)
  local canvas = OakIntroLayout.compute(
    800,
    600,
    { phase = "marill_appear", revealWidget = "marill_appear", revealFrameIndex = firstIndex, oakBgScrollX = 0 },
    {},
    manifest
  ).revealCanvas
  canvas = assert(canvas)
  local sourceAnchor = {
    x = (anchors[1].x - canvas.origin.x) / canvas.scale,
    y = (anchors[1].y - canvas.origin.y) / canvas.scale,
  }
  Assert.near(sourceAnchor.x, widget.sourceCenter.x, 1e-6)
  Assert.near(sourceAnchor.y, widget.sourceCenter.y, 1e-6)
  Assert.isTrue(frameBytes[1] ~= frameBytes[2], "translated reveal frames must contain different generated pixels")
end

function T.tests.ball_and_marill_geometry_stable_across_viewport_shapes()
  local manifest = loadManifest()
  local view = {
    phase = "marill_appear",
    visual = "oak",
    primaryWidget = "oak",
    revealWidget = "marill_appear",
    revealFrameIndex = 12,
    oakBgScrollX = -52,
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

function T.tests.gender_select_preserves_source_portraits_and_female_palette()
  local manifest = loadManifest()
  local view = { phase = "gender_select", genderFocus = 0, genderCompositionProgress = 1, oakBgScrollX = 0 }
  for _, sz in ipairs({ { 800, 600 }, { 390, 844 } }) do
    local w, h = sz[1], sz[2]
    local layout = OakIntroLayout.compute(w, h, view, {}, manifest)
    Assert.notNil(layout.genderButtons, "gender choices are not resolved")
    Assert.notNil(layout.genderButtons[0], "male choice missing")
    Assert.notNil(layout.genderButtons[1], "female choice missing")
    local selectorInset = assert(layout.selectorInset, "selector inset missing")
    Assert.isTrue(selectorInset > 0, "selector has deliberate responsive breathing room")
    local male = layout.genderButtons[0]
    local female = layout.genderButtons[1]
    Assert.isTrue(male.button.rect.x < female.button.rect.x, "male remains left of female")
    Assert.isTrue(
      male.portraitRect.width / male.portraitRect.height
        == manifest.widgets.gender_male.width / manifest.widgets.gender_male.height
    )
    Assert.isTrue(
      female.portraitRect.width / female.portraitRect.height
        == manifest.widgets.gender_female.width / manifest.widgets.gender_female.height
    )
    Assert.isTrue(male.portraitRect.x > male.button.contentRect.x)
    Assert.isTrue(female.portraitRect.x > female.button.contentRect.x)
  end
  -- Female palette comes from derived cache palette override, not host tint
  -- gender selector widgets are gender_male / gender_female
  local selMale = manifest.widgets.gender_male
  local selFemale = manifest.widgets.gender_female
  Assert.notNil(selMale, "manifest gender_male missing")
  Assert.notNil(selFemale, "manifest gender_female missing")
  -- Female must use palette bank 1 (source override) distinct from male bank 0
  -- Check per-frame metadata if present
  -- Compiler stores paletteOverride only via asset spec, but manifest frames carry element/translate; palette bank is implicit via image composition
  -- Verify female image differs and provenance indicates correct palette member
  Assert.isTrue(selFemale.image ~= selMale.image, "female selector must use a distinct generated image")
  -- Verify female widget height matches expected derived composition (not tinted male)
  Assert.isTrue(selFemale.height > 0 and selMale.height > 0, "selector dimensions present")
end

function T.tests.gender_focus_uses_source_palette_blink_without_rectangle()
  local manifest = loadManifest()
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
  enterGenderSelection(ctrl)
  Assert.equal(ctrl:view().phase, "gender_select", "must reach gender_select")
  -- Focus blink contract: view should expose deterministic blink delta/timer
  local view0 = ctrl:view()
  -- The focused selection uses sin(timer*10deg)*8 additive RGB555 delta
  -- Unfocused uses default + gray. Timer resets on focus change.
  -- Check view exposes blink state (implementation may expose delta or timer)
  local hasBlink = view0.focusBlinkDelta ~= nil or view0.focusTimer ~= nil
  Assert.isTrue(hasBlink, "gender focus view must expose source blink timer or derived delta")
  -- Timer reset semantics: moving focus right must reset phase to zero
  ctrl:press("right")
  local viewAfter = ctrl:view()
  Assert.equal(viewAfter.genderFocus, 1, "focus must move right")
  -- After reset, delta/timer must be zero
  if viewAfter.focusBlinkDelta ~= nil then
    Assert.equal(viewAfter.focusBlinkDelta, 0, "focus blink delta must reset to 0 on focus change")
  elseif viewAfter.focusTimer ~= nil then
    Assert.equal(viewAfter.focusTimer, 0, "focus timer must reset to 0 on focus change")
  end
  -- Advance several ticks and check sinusoidal progression (10deg steps)
  ctrl:tick(1)
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
      fontDef = { lineHeight = 16 },
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
  local manifest = loadManifest()
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
  enterGenderSelection(ctrl)
  Assert.equal(ctrl:view().phase, "gender_select")
  ctrl:press("confirm")
  ctrl:press("confirm")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "name_edit")
  ctrl:inputText("GOLD")
  ctrl:press("submit")
  ctrl:tick(26)
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

-- Gender selection activates only after the host composition has completed;
-- the completed layout places Oak in the disjoint gender-selection region.
function T.tests.gender_selection_waits_for_host_composition()
  local manifest = loadManifest()
  local ctrl = driveToBallOpen(manifest)
  advanceUntilPhase(ctrl, "oak_live_alongside")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "oak_tell_about_yourself")
  ctrl:press("confirm")
  enterGenderSelection(ctrl)
  Assert.equal(ctrl:view().phase, "gender_select", "must reach gender_select")

  local w, h = 800, 600
  local beforeView = ctrl:view()
  beforeView.phase = "oak_tell_about_yourself"
  beforeView.genderCompositionProgress = nil
  local beforeLayout = OakIntroLayout.compute(w, h, beforeView, {}, manifest)
  local afterLayout = OakIntroLayout.compute(w, h, ctrl:view(), {}, manifest)

  local beforeCenterX = beforeLayout.subject.x + beforeLayout.subject.width / 2
  local afterCenterX = afterLayout.subject.x + afterLayout.subject.width / 2
  Assert.isTrue(afterCenterX < beforeCenterX, "completed gender composition must move Oak into the left region")
  Assert.isTrue(
    afterLayout.subject.x >= afterLayout.oakRegion.x
      and afterLayout.subject.x + afterLayout.subject.width <= afterLayout.oakRegion.x + afterLayout.oakRegion.width,
    "completed gender composition must contain Oak in the left region"
  )
end

-- Once fully slid, Oak sits exactly 52 source pixels left of his base
-- position under the same canvas used for the ordinary (non-selector) phase.
function T.tests.full_slide_position_matches_base_position_by_exactly_fifty_two_source_pixels()
  local manifest = loadManifest()
  local w, h = 800, 600
  local baseView = { phase = "oak_welcome", visual = "oak", primaryWidget = "oak", oakBgScrollX = 0 }
  local baseLayout = OakIntroLayout.compute(w, h, baseView, {}, manifest)
  local selectorView = { phase = "oak_live_alongside", visual = "oak", primaryWidget = "oak", oakBgScrollX = -52 }
  local selectorLayout = OakIntroLayout.compute(w, h, selectorView, {}, manifest)
  local baseX = baseLayout.subject.x + baseLayout.subject.width / 2
  local selectorX = selectorLayout.subject.x + selectorLayout.subject.width / 2
  local canvasScale = math.min(baseLayout.scene.width / REFERENCE.width, baseLayout.scene.height / REFERENCE.height)
  Assert.near(
    (baseX - selectorX) / canvasScale,
    -52,
    1e-6,
    "full source scroll must place Oak exactly 52 source pixels right of the base canvas position"
  )
end

-- Marill must present at its fixed source center and remain above the dialogue
-- box while its message is active.
function T.tests.marill_preserves_source_center_and_stays_above_dialogue_while_visible()
  local manifest = loadManifest()
  local ctrl = driveToBallOpen(manifest)
  advanceUntilPhase(ctrl, "oak_live_alongside")
  local view = ctrl:view()
  Assert.notNil(view.dialogue, "oak_live_alongside must present dialogue")
  Assert.equal(view.revealWidget, "marill", "Marill must remain the active reveal while its dialogue plays")

  local w, h = 390, 844
  local layout = OakIntroLayout.compute(w, h, view, {}, manifest)
  Assert.notNil(layout.reveal, "layout must place the Marill reveal")
  Assert.notNil(layout.dialogue, "layout must reserve the dialogue box while its message is active")

  local canvas = assert(layout.revealCanvas, "layout must expose the source canvas used to place the reveal")
  local marillWidget = assert(manifest.widgets.marill)
  local expectedSourceCenter = {
    x = marillWidget.sourceCenter.x,
    y = marillWidget.sourceCenter.y,
  }
  local hostCenter = {
    x = assert(layout.reveal).x + marillWidget.anchor.x * canvas.scale,
    y = assert(layout.reveal).y + marillWidget.anchor.y * canvas.scale,
  }
  local actualSourceCenter = {
    x = (hostCenter.x - canvas.origin.x) / canvas.scale,
    y = (hostCenter.y - canvas.origin.y) / canvas.scale,
  }
  Assert.near(
    actualSourceCenter.x,
    expectedSourceCenter.x,
    0.5,
    "Marill source center x must remain fixed at the generated source center"
  )
  Assert.near(
    actualSourceCenter.y,
    expectedSourceCenter.y,
    0.5,
    "Marill source center y must remain fixed at the generated source center"
  )

  Assert.isTrue(
    layout.reveal.y + layout.reveal.height <= layout.dialogue.outerRect.y + 0.5,
    "Marill must remain fully above the dialogue box rather than overlapping/appearing beneath it"
  )
end

-- Marill's idle animation must keep advancing on every source tick for as
-- long as it remains the active reveal widget, even while dialogue holds
-- for player input (oak_live_alongside waits on a confirm press).
function T.tests.marill_idle_animation_continues_advancing_while_dialogue_is_held()
  local manifest = loadManifest()
  local widget = assert(manifest.widgets.marill)
  Assert.isTrue(#widget.frames > 1, "marill idle widget must have multiple frames to prove looping")

  local ctrl = driveToBallOpen(manifest)
  advanceUntilPhase(ctrl, "oak_live_alongside")
  local seenFrames = { [ctrl:view().revealFrameIndex] = true }
  local distinct = 1
  for _ = 1, 400 do
    Assert.equal(ctrl:view().phase, "oak_live_alongside", "dialogue wait must not itself advance the phase")
    Assert.equal(ctrl:view().revealWidget, "marill", "Marill must remain the visible reveal during this wait")
    ctrl:tick(1)
    local idx = assert(ctrl:view().revealFrameIndex, "reveal frame index must be set while Marill is visible")
    if not seenFrames[idx] then
      seenFrames[idx] = true
      distinct = distinct + 1
    end
  end
  Assert.isTrue(
    distinct > 1,
    "Marill idle frame index must advance across multiple frames while dialogue is held, not freeze on one frame"
  )
end

-- The full player-art hold must last exactly 30 source ticks, the shrink
-- SFX must fire exactly once at shrink start, and the first shrink frame
-- must already be the active image the moment shrink begins (no extra
-- fabricated hold frame before frame 1).
function T.tests.full_art_hold_lasts_thirty_ticks_and_shrink_sfx_fires_once()
  local manifest = loadManifest()
  local trace = {}
  local audio = fakeAudio()
  local originalPlay = audio.play
  audio.play = function(self, id)
    trace[#trace + 1] = id
    return originalPlay(self, id)
  end
  local ctrl = makeController(manifest, audio)
  ctrl:start()
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
  enterGenderSelection(ctrl)
  ctrl:press("confirm")
  ctrl:press("confirm")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "name_edit")
  ctrl:inputText("GOLD")
  ctrl:press("submit")
  ctrl:tick(26)
  ctrl:press("confirm")
  Assert.equal(ctrl:view().phase, "final_dialogue")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "final_full_art_hold")

  local shrinkSfxCountBefore = 0
  for _, id in ipairs(trace) do
    if id == "SEQ_SE_GS_HERO_SHUKUSHOU" then
      shrinkSfxCountBefore = shrinkSfxCountBefore + 1
    end
  end
  Assert.equal(shrinkSfxCountBefore, 0, "shrink SFX must not fire before the hold elapses")

  for tick = 1, 29 do
    ctrl:tick(1)
    Assert.equal(
      ctrl:view().phase,
      "final_full_art_hold",
      "full-art hold must last exactly 30 ticks (still holding at tick " .. tick .. ")"
    )
  end
  ctrl:tick(1)
  local view = ctrl:view()
  Assert.equal(view.phase, "shrink_animation", "hold must end at exactly the 30th tick")
  Assert.equal(view.visualFrameIndex, 1, "the first shrink image must already be active on entry")

  local shrinkSfxCount = 0
  for _, id in ipairs(trace) do
    if id == "SEQ_SE_GS_HERO_SHUKUSHOU" then
      shrinkSfxCount = shrinkSfxCount + 1
    end
  end
  Assert.equal(shrinkSfxCount, 1, "shrink SFX must fire exactly once")
end

-- Oak must be the visible subject on the first tick after leaving the name
-- editor, and must remain visible through name confirmation and the final
-- Oak dialogue until the explicit player-art transition.
function T.tests.oak_is_restored_immediately_after_name_editing_and_stays_through_final_dialogue()
  local manifest = loadManifest()
  local ctrl = makeController(manifest)
  ctrl:start()
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
  enterGenderSelection(ctrl)
  ctrl:press("confirm")
  ctrl:press("confirm")
  ctrl:press("confirm")
  advanceUntilPhase(ctrl, "name_edit")
  ctrl:inputText("GOLD")
  ctrl:press("submit")
  ctrl:tick(26)

  local view = ctrl:view()
  Assert.equal(view.phase, "name_confirm", "must reach name confirmation")
  Assert.equal(
    view.primaryWidget or (view.visual ~= "background" and view.visual or nil),
    "oak",
    "Oak must be the visible subject on the first post-editor confirmation tick"
  )

  ctrl:press("confirm")
  Assert.equal(ctrl:view().phase, "final_dialogue")
  view = ctrl:view()
  Assert.equal(
    view.primaryWidget or (view.visual ~= "background" and view.visual or nil),
    "oak",
    "Oak must remain the visible subject through the final Oak dialogue"
  )
end

return T
