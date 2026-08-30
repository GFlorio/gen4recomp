-- FieldRuntime scheduling coverage uses recording collaborators at the
-- coordinator boundary, without constructing a cache-backed field session.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldSession = require("libs.engine.src.FieldSession")
local PlayTime = require("libs.engine.src.PlayTime")

local T = {
  metadata = {
    tags = { "field", "transition", "scheduler" },
  },
  tests = {},
}

-- The production script screen-fade controller is always composed and
-- always advanced from the same 60 Hz presentation-frame branch as the
-- ordinary transition fade; this fake records its own call marker so tests
-- can prove its timeline is identical regardless of audio composition.
local function screenFadeFake(calls)
  return {
    fadeDone = function()
      return true
    end,
    updateSourceFrame = function()
      calls[#calls + 1] = "screen_fade"
    end,
  }
end

local function runtimeWithAudio(calls)
  local transition = {
    phase = "idle",
    error = nil,
    updateSourceFrame = function()
      calls[#calls + 1] = "presentation"
    end,
    consumeCompleted = function() end,
  }
  local audio = {
    updateSoundFrame = function()
      calls[#calls + 1] = "audio"
    end,
  }
  local runtime = setmetatable({
    presentationFrameAccumulator = 0,
    audioFrameAccumulator = 0,
    audio = audio,
    session = {
      accumulator = FieldSession.FIXED_DT - 1 / 60,
      updateFixed = function()
        calls[#calls + 1] = "field"
        transition.phase = "fade_out"
      end,
    },
    transition = transition,
    screenFade = screenFadeFake(calls),
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime
end

local function runtimeWithoutAudio(calls)
  local transition = {
    phase = "idle",
    error = nil,
    updateSourceFrame = function()
      calls[#calls + 1] = "presentation"
    end,
    consumeCompleted = function() end,
  }
  local runtime = setmetatable({
    presentationFrameAccumulator = 0,
    audioFrameAccumulator = 0,
    session = {
      accumulator = FieldSession.FIXED_DT - 1 / 60,
      updateFixed = function()
        calls[#calls + 1] = "field"
        transition.phase = "fade_out"
      end,
    },
    transition = transition,
    screenFade = screenFadeFake(calls),
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime
end

local function runtimeForSemanticCatchUp(counters)
  local playTime = PlayTime.new(0.9)
  playTime:start()
  return setmetatable({
    presentationFrameAccumulator = 0,
    audioFrameAccumulator = 0,
    audio = {
      updateSoundFrame = function()
        counters.audio = counters.audio + 1
      end,
    },
    playTime = playTime,
    session = {
      accumulator = 0,
      updateFixed = function()
        counters.field = counters.field + 1
      end,
    },
    transition = {
      phase = "idle",
      error = nil,
      updateSourceFrame = function()
        counters.presentation = counters.presentation + 1
      end,
      consumeCompleted = function() end,
    },
    screenFade = {
      fadeDone = function()
        return true
      end,
      updateSourceFrame = function()
        counters.screenFade = counters.screenFade + 1
      end,
    },
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
end

function T.tests.large_host_delta_is_bounded_across_semantic_clocks()
  local counters = { field = 0, presentation = 0, screenFade = 0, audio = 0 }
  local runtime = runtimeForSemanticCatchUp(counters)

  runtime:update(10)

  Assert.equal(counters.field, FieldSession.MAX_CATCH_UP_TICKS)
  Assert.equal(counters.presentation, 10)
  Assert.equal(counters.screenFade, 10)
  Assert.equal(counters.audio, 10)
  Assert.equal(runtime.playTime:seconds(), 1)
  Assert.isTrue(runtime.session.accumulator < FieldSession.FIXED_DT)
  Assert.isTrue(runtime.presentationFrameAccumulator < 1 / 60)
  Assert.isTrue(runtime.audioFrameAccumulator < 1 / 60)
end

function T.tests.discarded_host_lag_is_not_replayed_on_the_next_update()
  local counters = { field = 0, presentation = 0, screenFade = 0, audio = 0 }
  local runtime = runtimeForSemanticCatchUp(counters)

  runtime:update(10)
  counters.field = 0
  counters.presentation = 0
  counters.screenFade = 0
  counters.audio = 0

  runtime:update(1 / 60)

  Assert.equal(counters.field, 0)
  Assert.equal(counters.presentation, 1)
  Assert.equal(counters.screenFade, 1)
  Assert.equal(counters.audio, 1)
  Assert.isTrue(runtime.presentationFrameAccumulator < 1 / 60)
  Assert.isTrue(runtime.audioFrameAccumulator < 1 / 60)
end

function T.tests.transition_start_discards_stale_presentation_residual()
  local calls = {}
  local runtime = runtimeWithoutAudio(calls)

  runtime:update(1 / 60)
  Assert.deepEqual(calls, { "field" }, "the field boundary must precede a fresh transition presentation frame")
  Assert.equal(runtime.transition.phase, "fade_out")

  runtime:update(1 / 60)
  Assert.deepEqual(
    calls,
    { "field", "presentation", "screen_fade" },
    "only elapsed time after transition start may produce its first presentation frame"
  )
end

function T.tests.audio_does_not_change_presentation_clock_order()
  local calls = {}
  local runtime = runtimeWithAudio(calls)

  runtime:update(1 / 60)
  Assert.deepEqual(
    calls,
    { "field", "audio" },
    "field must precede tied audio and stale presentation must be discarded"
  )

  runtime:update(1 / 60)
  Assert.deepEqual(calls, { "field", "audio", "presentation", "screen_fade", "audio" })
end

-- The script screen-fade source-frame cadence must not depend on whether an
-- audio service is composed: strip the interleaved "audio" markers from the
-- audio-present run and the two timelines must be identical.
function T.tests.screen_fade_source_frame_timeline_is_identical_with_and_without_audio()
  local withAudioCalls = {}
  local withoutAudioCalls = {}
  local withAudio = runtimeWithAudio(withAudioCalls)
  local withoutAudio = runtimeWithoutAudio(withoutAudioCalls)

  for _ = 1, 4 do
    withAudio:update(1 / 60)
    withoutAudio:update(1 / 60)
  end

  local filteredWithAudio = {}
  for _, call in ipairs(withAudioCalls) do
    if call ~= "audio" then
      filteredWithAudio[#filteredWithAudio + 1] = call
    end
  end
  Assert.deepEqual(
    filteredWithAudio,
    withoutAudioCalls,
    "the screen-fade/transition presentation timeline must not depend on audio composition"
  )
end

function T.tests.zero_delta_does_not_advance_any_clock()
  local calls = {}
  local runtime = setmetatable({
    presentationFrameAccumulator = 0,
    audioFrameAccumulator = 0,
    session = {
      accumulator = 0,
      updateFixed = function()
        calls[#calls + 1] = "field"
      end,
    },
    transition = {
      phase = "idle",
      error = nil,
      updateSourceFrame = function()
        calls[#calls + 1] = "presentation"
      end,
      consumeCompleted = function() end,
    },
    screenFade = screenFadeFake(calls),
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)

  runtime:update(0)
  Assert.deepEqual(calls, {})
  Assert.equal(runtime.presentationFrameAccumulator, 0)
  Assert.equal(runtime.audioFrameAccumulator, 0)
end

return T
