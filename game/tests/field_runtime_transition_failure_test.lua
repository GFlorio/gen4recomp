-- FieldRuntime treats a transition preparation failure as a terminal
-- presentation state. The first failing update promotes the transition
-- error after completing that tick; later updates do no background or
-- simulation work until reset boots a fresh runtime.

local Assert = require("tests.support.Assert")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldRuntime = require("game.src.game.FieldRuntime")

local T = {}

local function runtimeWithTransitionError(transitionError)
  local calls = { warmup = 0, session = 0 }
  local runtime = setmetatable({
    presentationFrameAccumulator = 0,
    scripts = {
      warmup = {
        update = function()
          calls.warmup = calls.warmup + 1
        end,
      },
    },
    session = {
      accumulator = 0,
      update = function()
        calls.session = calls.session + 1
      end,
      updateFixed = function()
        calls.session = calls.session + 1
      end,
    },
    transition = {
      error = transitionError,
      warpContext = {
        sourceMapId = 61,
        sourceWarpId = 0,
        destinationMapId = 60,
        destinationWarpId = 0,
      },
      consumeCompleted = function()
        return nil
      end,
      updateSourceFrame = function() end,
      updateFixed = function() end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
    fieldEntranceIndicator = {
      updateFixed = function() end,
    },
  }, FieldRuntime)
  return runtime, calls
end

function T.runtime_freezes_simulation_and_warmup_after_promoting_transition_error()
  local tostringCalls = 0
  local transitionError = setmetatable({}, {
    __tostring = function()
      tostringCalls = tostringCalls + 1
      return "destination preparation failed"
    end,
  })
  local runtime, calls = runtimeWithTransitionError(transitionError)

  runtime:update(1 / 30)
  Assert.equal(calls.warmup, 1, "the failing update completes its warm-up slice")
  Assert.equal(calls.session, 1, "the failing update completes its session tick")
  Assert.equal(runtime.errorText, "destination preparation failed\nsource map 61 warp 0 -> map 60 warp 0")

  runtime:update(1 / 30)
  Assert.equal(calls.warmup, 1, "terminal runtime does not continue registry warm-up")
  Assert.equal(calls.session, 1, "terminal runtime does not continue session updates")
  Assert.equal(tostringCalls, 1, "the transition failure is formatted once")
  Assert.equal(runtime.errorText, "destination preparation failed\nsource map 61 warp 0 -> map 60 warp 0")
end

function T.reset_clears_terminal_error_and_reboots_the_runtime()
  local resetCalls = 0
  local loadCalls = 0
  local runtime = setmetatable({
    errorText = "terminal transition failure",
    saveStore = {
      reset = function()
        resetCalls = resetCalls + 1
      end,
    },
  }, FieldRuntime)
  function runtime:_load()
    loadCalls = loadCalls + 1
  end

  runtime:reset()

  Assert.equal(resetCalls, 1, "reset clears the save store before rebooting")
  Assert.equal(loadCalls, 1, "reset reboots the runtime")
  Assert.isNil(runtime.errorText, "reset clears the terminal presentation")
end

function T.source_frame_started_on_the_same_boundary_as_field_tick_is_exposed()
  local fadeStarted = false
  local coefficient = 0
  local runtime = setmetatable({
    presentationFrameAccumulator = 0,
    scripts = {},
    session = {
      accumulator = FieldSession.FIXED_DT - 1 / 60,
      updateFixed = function()
        fadeStarted = true
      end,
    },
    transition = {
      error = nil,
      updateSourceFrame = function()
        coefficient = fadeStarted and 2 or 0
      end,
      consumeCompleted = function()
        return nil
      end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)

  runtime:update(1 / 60)
  Assert.equal(coefficient, 2, "the first source-frame fade coefficient must be visible immediately")
end

function T.transition_started_after_a_prior_presentation_frame_defers_the_fade()
  local sourceFrames = 0
  local runtime
  runtime = setmetatable({
    presentationFrameAccumulator = 0,
    scripts = {},
    session = {
      accumulator = 0,
      updateFixed = function()
        runtime.transition.phase = "fade_out"
      end,
    },
    transition = {
      phase = "idle",
      error = nil,
      updateSourceFrame = function()
        if runtime.transition.phase ~= "idle" then
          sourceFrames = sourceFrames + 1
        end
      end,
      consumeCompleted = function()
        return nil
      end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)

  runtime:update(1 / 30)
  Assert.equal(sourceFrames, 0, "a transition must not consume a later source frame in its input update")

  runtime:update(1 / 60)
  Assert.equal(sourceFrames, 1, "the first source frame must be consumed by the next presentation update")
end

return { tests = T }
