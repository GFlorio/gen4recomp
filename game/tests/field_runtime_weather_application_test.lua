-- Runtime weather tests exercise activation-time sampling and fog selection
-- through FieldRuntime methods without constructing a cache-backed session.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldWeatherCache = require("libs.assets.src.FieldWeatherCache")

local T = {}

local WEATHER_MAP = 999
local BASE_MAP = 1000

local function rampTable()
  local values = {}
  for i = 1, 32 do
    values[i] = (i - 1) * 4
  end
  return values
end

local function validCatalog()
  local presets = {}
  for id = 0, 13 do
    local enabled = id ~= 0 and id ~= 7
    presets[id] = {
      enabled = enabled,
      color = 0,
      offset = 0,
      slope = 0,
      alpha = enabled and 31 or 0,
      table = rampTable(),
    }
  end
  return {
    schema = FieldWeatherCache.SCHEMA,
    presets = presets,
    rules = {
      {
        kind = "calendar_map_override",
        mapId = WEATHER_MAP,
        weatherId = 8,
        requireNoPenalty = true,
        dates = { { month = 1, day = 1 } },
      },
      {
        kind = "map_var_equals",
        mapId = BASE_MAP,
        varId = 0x4037,
        value = 0xF229,
        weatherId = 0,
      },
      {
        kind = "weather_flag_override",
        fromWeatherId = 9,
        flagId = 2420,
        weatherId = 0,
      },
      {
        kind = "weather_flag_override",
        fromWeatherId = 11,
        flagId = 2419,
        weatherId = 12,
      },
    },
  }
end

local function runtimeWithClock(catalog, calls)
  local clock = {
    today = function()
      calls.today = calls.today + 1
      return { month = 1, day = 1 }
    end,
    hasPenalty = function()
      calls.penalty = calls.penalty + 1
      return false
    end,
  }
  return setmetatable({
    weatherCatalog = catalog,
    weatherClock = clock,
    eventState = FieldEventState.new(),
    scripts = {},
    session = { update = function() end },
    applicationHost = {
      error = function()
        return nil
      end,
    },
    transition = {
      error = nil,
      consumeCompleted = function()
        return false
      end,
    },
  }, FieldRuntime)
end

function T.runtime_samples_weather_on_activation_and_selects_the_matching_fog()
  local catalog = validCatalog()
  local valid, err = FieldWeatherCache.validateCatalog(catalog)
  Assert.isTrue(valid, tostring(err))

  local calls = { today = 0, penalty = 0 }
  local runtime = runtimeWithClock(catalog, calls)
  local baseFog = { name = "compiled base fog" }
  local overrideMap = {
    mapId = WEATHER_MAP,
    scene = { weatherId = 5, fog = baseFog },
    sceneRuntime = {},
  }
  local baseMap = {
    mapId = BASE_MAP,
    scene = { weatherId = 5, fog = baseFog },
    sceneRuntime = {},
  }

  runtime:_applyEffectiveWeather(overrideMap)
  Assert.equal(calls.today, 1)
  Assert.equal(calls.penalty, 1)
  Assert.equal(overrideMap.effectiveWeatherId, 8)
  Assert.equal(overrideMap.sceneRuntime.fog, catalog.presets[8])

  runtime:update(1 / 30)
  runtime:update(1 / 30)
  runtime:update(1 / 30)
  Assert.equal(calls.today, 1, "ordinary updates must not resample the weather date")
  Assert.equal(calls.penalty, 1, "ordinary updates must not resample the penalty state")

  runtime:_applyEffectiveWeather(baseMap)
  Assert.equal(calls.today, 2)
  Assert.equal(calls.penalty, 2)
  Assert.equal(baseMap.effectiveWeatherId, 5)
  Assert.equal(baseMap.sceneRuntime.fog, baseFog, "unchanged weather must preserve compiled base fog")
end

return { tests = T, metadata = { tags = { "field", "weather" } } }
