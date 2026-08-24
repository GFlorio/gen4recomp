-- FieldRuntime scheduling coverage uses recording collaborators at the
-- coordinator boundary, without constructing a cache-backed field session.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldSession = require("libs.engine.src.FieldSession")

local T = {
  metadata = {
    tags = { "field", "transition", "scheduler" },
  },
  tests = {},
}

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
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime
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
    { "field", "presentation" },
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
  Assert.deepEqual(calls, { "field", "audio", "presentation", "audio" })
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
