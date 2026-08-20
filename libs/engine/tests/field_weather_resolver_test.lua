-- Pure resolver conformance for weather override families.

local Assert = require("tests.support.Assert")
local FieldWeatherCache = require("libs.assets.src.FieldWeatherCache")
local FieldEventState = require("libs.engine.src.FieldEventState")

local T = {}

local MOUNT_SILVER_SUMMIT = 465
local LAKE_OF_RAGE = 88
local VAR_LAKE = 0x4037
local VAL_LAKE = 0xF229
local FLAG_DEFOG = 2420
local FLAG_FLASH = 2419

local DIAMOND_DUST_DATES = {
  { month = 1, day = 1 },
  { month = 1, day = 31 },
  { month = 2, day = 1 },
  { month = 2, day = 29 },
  { month = 3, day = 15 },
  { month = 10, day = 10 },
  { month = 12, day = 3 },
  { month = 12, day = 31 },
}

local function requireResolver()
  local ok, mod = pcall(require, "libs.engine.src.FieldWeatherResolver")
  if not ok then
    error("FieldWeatherResolver is absent: calendar and weather rule resolution cannot be evaluated", 0)
  end
  return mod
end

local function rampTable()
  local t = {}
  for i = 1, 32 do
    t[i] = (i - 1) * 4
  end
  return t
end

local function flashTable()
  local t = {}
  for i = 1, 32 do
    t[i] = 255
  end
  return t
end

local function validPresets()
  local presets = {}
  for id = 0, 13 do
    local enabled = (id ~= 0 and id ~= 7)
    presets[id] = {
      enabled = enabled,
      color = 0,
      offset = 0,
      slope = 0,
      alpha = enabled and 31 or 0,
      table = rampTable(),
    }
  end
  -- make flash presets distinct but still valid
  presets[11].table = flashTable()
  presets[12].table = flashTable()
  presets[11].slope = 10
  presets[12].slope = 10
  return presets
end

local function canonicalCatalog()
  return {
    schema = FieldWeatherCache.SCHEMA,
    presets = validPresets(),
    rules = {
      {
        kind = "calendar_map_override",
        mapId = MOUNT_SILVER_SUMMIT,
        weatherId = 8,
        requireNoPenalty = true,
        dates = DIAMOND_DUST_DATES,
      },
      {
        kind = "map_var_equals",
        mapId = LAKE_OF_RAGE,
        varId = VAR_LAKE,
        value = VAL_LAKE,
        weatherId = 0,
      },
      {
        kind = "weather_flag_override",
        fromWeatherId = 9,
        flagId = FLAG_DEFOG,
        weatherId = 0,
      },
      {
        kind = "weather_flag_override",
        fromWeatherId = 11,
        flagId = FLAG_FLASH,
        weatherId = 12,
      },
    },
  }
end

function T.resolver_applies_diamond_dust_on_listed_dates_without_penalty()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  local baseWeather = 5
  for _, date in ipairs(DIAMOND_DUST_DATES) do
    local effective = Resolver.resolve(catalog, {
      mapId = MOUNT_SILVER_SUMMIT,
      baseWeatherId = baseWeather,
      eventState = FieldEventState.new(),
      date = { month = date.month, day = date.day },
      hasPenalty = false,
    })
    Assert.equal(
      effective,
      8,
      "listed date " .. date.month .. "/" .. date.day .. " without penalty must become Diamond Dust 8"
    )
  end
end

function T.resolver_preserves_base_when_penalty_blocks_diamond_dust()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  local baseWeather = 5
  local listed = DIAMOND_DUST_DATES[1]
  local effective = Resolver.resolve(catalog, {
    mapId = MOUNT_SILVER_SUMMIT,
    baseWeatherId = baseWeather,
    eventState = FieldEventState.new(),
    date = { month = listed.month, day = listed.day },
    hasPenalty = true,
  })
  Assert.equal(effective, baseWeather, "listed date with penalty must preserve base")
end

function T.resolver_preserves_base_on_non_listed_dates()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  local baseWeather = 5
  local effective = Resolver.resolve(catalog, {
    mapId = MOUNT_SILVER_SUMMIT,
    baseWeatherId = baseWeather,
    eventState = FieldEventState.new(),
    date = { month = 1, day = 2 },
    hasPenalty = false,
  })
  Assert.equal(effective, baseWeather, "non-listed date must preserve base even without penalty")
  local effective2 = Resolver.resolve(catalog, {
    mapId = MOUNT_SILVER_SUMMIT,
    baseWeatherId = baseWeather,
    eventState = FieldEventState.new(),
    date = { month = 6, day = 15 },
    hasPenalty = false,
  })
  Assert.equal(effective2, baseWeather)
end

function T.resolver_applies_lake_of_rage_only_for_exact_var_equality()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  local targetState = FieldEventState.new({ vars = { [VAR_LAKE] = VAL_LAKE } })
  local offByOneState = FieldEventState.new({ vars = { [VAR_LAKE] = VAL_LAKE - 1 } })
  local offByOneHigh = FieldEventState.new({ vars = { [VAR_LAKE] = VAL_LAKE + 1 } })
  local zeroState = FieldEventState.new()
  local base = 1
  local date = { month = 6, day = 15 }
  local exact = Resolver.resolve(catalog, {
    mapId = LAKE_OF_RAGE,
    baseWeatherId = base,
    eventState = targetState,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(exact, 0, "Lake of Rage with exact var equality must become 0")
  local differentMap = Resolver.resolve(catalog, {
    mapId = 60,
    baseWeatherId = base,
    eventState = targetState,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(differentMap, base, "different map with same var must preserve base")
  local offOne = Resolver.resolve(catalog, {
    mapId = LAKE_OF_RAGE,
    baseWeatherId = base,
    eventState = offByOneState,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(offOne, base, "off-by-one low must preserve base")
  local offHigh = Resolver.resolve(catalog, {
    mapId = LAKE_OF_RAGE,
    baseWeatherId = base,
    eventState = offByOneHigh,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(offHigh, base)
  local zero = Resolver.resolve(catalog, {
    mapId = LAKE_OF_RAGE,
    baseWeatherId = base,
    eventState = zeroState,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(zero, base)
end

function T.resolver_rewrites_weather_9_to_0_only_when_defog_flag_set()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  local withFlag = FieldEventState.new({ flags = { [FLAG_DEFOG] = true } })
  local withoutFlag = FieldEventState.new()
  local date = { month = 6, day = 15 }
  local rewrites = Resolver.resolve(catalog, {
    mapId = 60,
    baseWeatherId = 9,
    eventState = withFlag,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(rewrites, 0, "weather 9 with Defog must become 0")
  local stays = Resolver.resolve(catalog, {
    mapId = 60,
    baseWeatherId = 9,
    eventState = withoutFlag,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(stays, 9, "weather 9 without Defog must stay 9")
  for _, other in ipairs({ 0, 1, 8, 10, 11, 12 }) do
    local unchanged = Resolver.resolve(catalog, {
      mapId = 60,
      baseWeatherId = other,
      eventState = withFlag,
      date = date,
      hasPenalty = false,
    })
    Assert.equal(unchanged, other, "weather " .. other .. " with Defog must stay " .. other)
  end
end

function T.resolver_rewrites_weather_11_to_12_only_when_flash_flag_set()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  local withFlag = FieldEventState.new({ flags = { [FLAG_FLASH] = true } })
  local withoutFlag = FieldEventState.new()
  local date = { month = 6, day = 15 }
  local rewrites = Resolver.resolve(catalog, {
    mapId = 60,
    baseWeatherId = 11,
    eventState = withFlag,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(rewrites, 12, "weather 11 with Flash must become 12")
  local stays = Resolver.resolve(catalog, {
    mapId = 60,
    baseWeatherId = 11,
    eventState = withoutFlag,
    date = date,
    hasPenalty = false,
  })
  Assert.equal(stays, 11)
  for _, other in ipairs({ 0, 9, 10, 12, 8 }) do
    local unchanged = Resolver.resolve(catalog, {
      mapId = 60,
      baseWeatherId = other,
      eventState = withFlag,
      date = date,
      hasPenalty = false,
    })
    Assert.equal(unchanged, other)
  end
end

function T.resolver_applies_rules_in_order_fold_not_independently_to_base()
  local Resolver = requireResolver()
  -- A production-valid catalog where an earlier rule creates the weather that
  -- a later rule consumes.
  local synthetic = {
    schema = FieldWeatherCache.SCHEMA,
    presets = validPresets(),
    rules = {
      {
        kind = "calendar_map_override",
        mapId = 100,
        weatherId = 9,
        requireNoPenalty = true,
        dates = { { month = 1, day = 1 } },
      },
      {
        kind = "map_var_equals",
        mapId = LAKE_OF_RAGE,
        varId = VAR_LAKE,
        value = VAL_LAKE,
        weatherId = 0,
      },
      {
        kind = "weather_flag_override",
        fromWeatherId = 9,
        flagId = FLAG_DEFOG,
        weatherId = 0,
      },
      {
        kind = "weather_flag_override",
        fromWeatherId = 11,
        flagId = FLAG_FLASH,
        weatherId = 12,
      },
    },
  }
  local valid, err = FieldWeatherCache.validateCatalog(synthetic)
  Assert.isTrue(valid, tostring(err))
  local withFlag = FieldEventState.new({ flags = { [FLAG_DEFOG] = true } })
  local effective = Resolver.resolve(synthetic, {
    mapId = 100,
    baseWeatherId = 5,
    eventState = withFlag,
    date = { month = 1, day = 1 },
    hasPenalty = false,
  })
  Assert.equal(
    effective,
    0,
    "ordered fold must apply second rule to the weather produced by the first, yielding 0 not 5 or 9"
  )
  local withoutSecond = Resolver.resolve(synthetic, {
    mapId = 100,
    baseWeatherId = 5,
    eventState = FieldEventState.new(),
    date = { month = 1, day = 1 },
    hasPenalty = false,
  })
  Assert.equal(withoutSecond, 9, "without Defog only the first rule applies")
end

function T.resolver_rejects_unknown_base_preset()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  Assert.throws(function()
    Resolver.resolve(catalog, {
      mapId = 60,
      baseWeatherId = 99,
      eventState = FieldEventState.new(),
      date = { month = 1, day = 1 },
      hasPenalty = false,
    })
  end)
end

function T.resolver_does_not_mutate_catalog()
  local Resolver = requireResolver()
  local catalog = canonicalCatalog()
  Resolver.resolve(catalog, {
    mapId = MOUNT_SILVER_SUMMIT,
    baseWeatherId = 5,
    eventState = FieldEventState.new(),
    date = { month = 1, day = 1 },
    hasPenalty = false,
  })
  Assert.equal(#catalog.rules, 4)
  Assert.equal(catalog.rules[1].weatherId, 8)
end

return { tests = T }
