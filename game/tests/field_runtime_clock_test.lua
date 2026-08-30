-- FieldRuntime adapts the injectable local civil clock independently for
-- weather dates and map-music day/night policy.

local Assert = require("tests.support.Assert")
local FieldAudio = require("game.src.game.audio.FieldAudio")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldSession = require("libs.engine.src.FieldSession")
local LocalClock = require("libs.engine.src.LocalClock")

local T = { tests = {} }

local function runtimeForSemanticClock(calls, options)
  options = options or {}
  local transition = {
    phase = "idle",
    error = nil,
    updateSourceFrame = function()
      calls[#calls + 1] = "transition"
    end,
    consumeCompleted = function() end,
  }
  local runtime = setmetatable({
    audio = options.audio == false and nil or {
      updateSoundFrame = function()
        calls[#calls + 1] = "audio"
      end,
    },
    audioSink = options.audioSink,
    session = {
      accumulator = 0,
      updateFixed = function()
        calls[#calls + 1] = "field"
        if options.startPresentationDuringField then
          transition.phase = "fade_out"
        end
      end,
    },
    transition = transition,
    screenFade = {
      fadeDone = function()
        return not options.startPresentationDuringField
      end,
      updateSourceFrame = function()
        calls[#calls + 1] = "screen_fade"
      end,
    },
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime
end

function T.tests.field_tick_owns_one_post_field_semantic_frame()
  local calls = {}
  local runtime = runtimeForSemanticClock(calls)

  runtime:update(FieldSession.FIXED_DT / 2)
  Assert.deepEqual(calls, {}, "a half field tick must not advance field, fade, or semantic audio")
  Assert.near(runtime.session.accumulator, FieldSession.FIXED_DT / 2)

  runtime:update(FieldSession.FIXED_DT / 2)
  Assert.deepEqual(calls, { "field", "transition", "screen_fade", "audio" })
  Assert.near(runtime.session.accumulator, 0)

  runtime:update(FieldSession.FIXED_DT)
  Assert.deepEqual(calls, {
    "field",
    "transition",
    "screen_fade",
    "audio",
    "field",
    "transition",
    "screen_fade",
    "audio",
  })
end

function T.tests.presentation_started_by_field_logic_updates_in_the_same_source_frame()
  local calls = {}
  local runtime = runtimeForSemanticClock(calls, { startPresentationDuringField = true })

  runtime:update(FieldSession.FIXED_DT)

  Assert.deepEqual(calls, { "field", "transition", "screen_fade", "audio" })
  Assert.equal(runtime.transition.phase, "fade_out")
end

function T.tests.semantic_audio_tracks_field_ticks_while_sink_tracks_host_updates()
  local combinedCalls = {}
  local combinedSinkUpdates = 0
  local combined = runtimeForSemanticClock(combinedCalls, {
    audioSink = {
      update = function()
        combinedSinkUpdates = combinedSinkUpdates + 1
      end,
    },
  })
  local splitCalls = {}
  local splitSinkUpdates = 0
  local split = runtimeForSemanticClock(splitCalls, {
    audioSink = {
      update = function()
        splitSinkUpdates = splitSinkUpdates + 1
      end,
    },
  })

  combined:update(2 * FieldSession.FIXED_DT)
  split:update(FieldSession.FIXED_DT)
  split:update(FieldSession.FIXED_DT)

  Assert.deepEqual(combinedCalls, splitCalls, "dt chunking must not change semantic audio state")
  Assert.deepEqual(combinedCalls, {
    "field",
    "transition",
    "screen_fade",
    "audio",
    "field",
    "transition",
    "screen_fade",
    "audio",
  })
  Assert.equal(combinedSinkUpdates, 1, "the output sink pumps once for the combined host update")
  Assert.equal(splitSinkUpdates, 2, "the output sink still follows host update calls")
end

function T.tests.weather_and_map_music_use_the_injected_local_clock()
  local originalLoad = FieldRuntime._load
  local originalCompose = FieldAudio.compose
  local originalDate = os.date
  local calls = 0
  local composition
  local clock = LocalClock.new(function()
    calls = calls + 1
    return { year = 2024, month = 2, day = 29, hour = 12, minute = 34, second = 56 }
  end)

  FieldRuntime._load = function() end
  ---@diagnostic disable-next-line: duplicate-set-field -- replace the production composer with a recording fake
  FieldAudio.compose = function(options)
    composition = options
    return {
      service = { enterMap = function() end },
      sink = nil,
    }
  end
  ---@diagnostic disable-next-line: duplicate-set-field -- prove the runtime does not read the host clock directly
  os.date = function()
    error("FieldRuntime must not read os.date directly")
  end

  local ok, err = xpcall(function()
    local runtime = FieldRuntime.new({
      saveId = "test-save",
      versionId = "heartgold",
      location = { mapSymbol = "MAP_NEW_BARK_ELMS_LAB_1F", fieldX = 6, fieldZ = 6, facing = "south" },
      playerData = {
        profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
        options = { textSpeed = "mid", textFrame = 0 },
      },
      worldState = {
        serialize = function()
          return {}
        end,
      },
    }, { localClock = clock })
    Assert.deepEqual(runtime.weatherClock:today(), { month = 2, day = 29 })
    ---@diagnostic disable-next-line: missing-fields -- the test only exercises the injected world loader
    runtime:_composeAudio({
      loadLua = function()
        return {}
      end,
    }, nil)
    Assert.equal(composition.dayNight(), "day")
    Assert.equal(calls, 2, "weather and map music each sample the shared clock boundary")
  end, debug.traceback)

  FieldRuntime._load = originalLoad
  FieldAudio.compose = originalCompose
  os.date = originalDate
  if not ok then
    error(err, 0)
  end
end

return T
