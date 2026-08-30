-- Production-composed Oak/profile transition checks using the generated cache
-- and the offscreen graphics host, without invoking the draw path.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local NewGame = require("game.src.game.NewGame")
local OakIntroComposition = require("game.src.game.OakIntroComposition")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {}

local function candidate(versionId)
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000001"
      end,
    },
    versionId = versionId,
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

local function compose(scope, versionId, width, height)
  local audio = FakeAudioOutput.new()
  local state = OakIntroComposition.compose({
    candidate = candidate(versionId),
    versionId = versionId,
    graphics = love.graphics,
    audioOutput = { audio = audio.audio, sound = audio.sound },
    clock = {
      nowLocal = function()
        return { year = 2026, month = 8, day = 27, hour = 12, minute = 0, second = 0 }
      end,
    },
    randomU32 = function()
      return 0x12345678
    end,
    width = width,
    height = height,
    textInputHost = { setTextInput = function() end },
  })
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  return state
end

local function finishDialogue(state)
  local messageKey = assert(state:view().messageKey, "scenario requires an active dialogue")
  for _ = 1, 20000 do
    if state:view().messageKey ~= messageKey then
      return
    end
    local status = state.dialogueController:status()
    if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
      state:keypressed("return")
    else
      state:tick(1)
    end
  end
  error("dialogue did not reach its semantic completion boundary: " .. messageKey)
end

local function advanceUntilMessage(state, messageKey)
  for _ = 1, 20000 do
    if state:view().messageKey == messageKey then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not open: " .. messageKey)
end

local function beginGenderComposition(state)
  advanceUntilMessage(state, "profile.gender_question")
  finishDialogue(state)
  state:keypressed("return")
  return state:view()
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

local function assertOakGeometry(view, oak)
  Assert.near(view.layout.subject.width, oak.width * view.layout.subject.scale)
  Assert.near(view.layout.subject.height, oak.height * view.layout.subject.scale)
end

T.wide_host_moves_oak_into_the_profile_region_before_selection = function(scope)
  local state = compose(scope, AcceptanceHarness.defaultVersion(), 1920, 1080)
  local first = beginGenderComposition(state)
  Assert.equal(first.genderCompositionProgress, 0)
  Assert.isNil(first.layout.genderHitRegions)

  local start = assert(first.layout.subject)
  local previous = start
  local samples = {}
  local final
  for frame = 0, 26 do
    if frame > 0 then
      state:tick(1)
    end
    local view = state:view()
    local progress = frame / 26
    Assert.near(view.genderCompositionProgress, progress)
    assertOakGeometry(view, state.manifest.widgets.oak)
    local subject = assert(view.layout.subject)
    samples[frame] = subject
    if frame < 26 then
      Assert.isNil(view.layout.genderHitRegions)
      Assert.isTrue(view.phase ~= "gender_select")
      Assert.isTrue(subject.x <= assert(previous).x)
    else
      final = view
    end
    previous = subject
  end

  final = assert(final)
  Assert.equal(final.phase, "gender_select")
  Assert.equal(final.genderCompositionProgress, 1)
  Assert.notNil(final.layout.genderHitRegions)
  Assert.isTrue(final.layout.oakRegion.x < final.layout.selectorRegion.x)
  Assert.isTrue(inside(final.layout.subject, final.layout.oakRegion))
  Assert.isTrue(disjoint(final.layout.oakRegion, final.layout.selectorRegion))
  local finalSubject = assert(final.layout.subject)
  Assert.isTrue(finalSubject.x < start.x)
  for frame = 0, 26 do
    local progress = frame / 26
    local subject = samples[frame]
    Assert.near(subject.x, start.x + (finalSubject.x - start.x) * progress)
    Assert.near(subject.y, start.y + (finalSubject.y - start.y) * progress)
    Assert.near(subject.scale, start.scale + (finalSubject.scale - start.scale) * progress)
  end
end

T.resized_tall_host_keeps_the_completed_profile_composition = function(scope)
  local state = compose(scope, AcceptanceHarness.defaultVersion(), 390, 844)
  local first = beginGenderComposition(state)
  Assert.equal(first.genderCompositionProgress, 0)
  state:tick(13)
  local middle = state:view()
  Assert.near(middle.genderCompositionProgress, 0.5)

  state:resize(430, 900)
  local resized = state:view()
  Assert.near(resized.genderCompositionProgress, 0.5)
  Assert.equal(resized.layout.oakRegion.y, resized.layout.safeFrame.y)

  state:tick(13)
  local completed = state:view()
  Assert.equal(completed.genderCompositionProgress, 1)
  Assert.equal(completed.phase, "gender_select")
  Assert.notNil(completed.layout.genderHitRegions)
  Assert.isTrue(inside(completed.layout.subject, completed.layout.oakRegion))

  state:keypressed("return")
  finishDialogue(state)
  Assert.equal(state:view().phase, "gender_confirm")
  state:keypressed("escape")
  local question = state:view()
  Assert.equal(question.phase, "gender_question")
  Assert.equal(question.genderCompositionProgress, 1)
  Assert.isTrue(inside(question.layout.subject, question.layout.oakRegion))
  Assert.near(question.layout.subject.x, completed.layout.subject.x)
  Assert.near(question.layout.subject.y, completed.layout.subject.y)
  Assert.near(question.layout.subject.scale, completed.layout.subject.scale)

  finishDialogue(state)
  local reentered = state:view()
  Assert.equal(reentered.phase, "gender_select")
  Assert.equal(reentered.genderCompositionProgress, 1)
  Assert.notNil(reentered.layout.genderHitRegions)
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
