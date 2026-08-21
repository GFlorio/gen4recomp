local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local function requireCache()
  local ok, mod = pcall(require, "libs.assets.src.FieldWeatherCache")
  if not ok then
    error("FieldWeatherCache is absent: runtime has no generated weather catalog authority", 0)
  end
  return mod
end

local T = {}

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
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

local function validPreset(id)
  local enabled = (id ~= 0 and id ~= 7)
  return {
    enabled = enabled,
    color = 0,
    offset = 0,
    slope = enabled and 3 or 0,
    alpha = enabled and 31 or 0,
    table = rampTable(),
  }
end

local function validCatalog()
  local presets = {}
  for id = 0, 13 do
    presets[id] = validPreset(id)
  end
  presets[11].table = flashTable()
  presets[12].table = flashTable()
  presets[11].slope = 10
  presets[12].slope = 10
  return {
    schema = "g4-field-weather-v1",
    presets = presets,
    rules = {
      {
        kind = "calendar_map_override",
        mapId = 465,
        weatherId = 8,
        requireNoPenalty = true,
        dates = { { month = 1, day = 1 } },
      },
      { kind = "map_var_equals", mapId = 88, varId = 0x4037, value = 0xF229, weatherId = 0 },
      { kind = "weather_flag_override", fromWeatherId = 9, flagId = 2420, weatherId = 0 },
      { kind = "weather_flag_override", fromWeatherId = 11, flagId = 2419, weatherId = 12 },
    },
  }
end

function T.contract_constants_flow_from_the_contract_owner()
  local FieldWeatherCache = requireCache()
  local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
  Assert.notNil(DerivedAssetContract.fieldWeather, "DerivedAssetContract must expose fieldWeather")
  Assert.equal(FieldWeatherCache.FORMAT, DerivedAssetContract.fieldWeather.cacheFormat)
  Assert.equal(FieldWeatherCache.SCHEMA, DerivedAssetContract.fieldWeather.schema)
  Assert.equal(FieldWeatherCache.SCHEMA, "g4-field-weather-v1")
  Assert.equal(FieldWeatherCache.FORMAT, "field-weather-cache-v1")
end

function T.ready_requires_matching_marker_and_valid_catalog_with_all_presets()
  local FieldWeatherCache = requireCache()
  local c = cache()
  local catalog = validCatalog()
  local marker = FieldWeatherCache.marker("rom-sha", "dep-hash")
  -- missing marker
  Assert.isFalse(FieldWeatherCache.isReady(c, marker))
  c:writeLua(FieldWeatherCache.catalogPath(), catalog)
  Assert.isFalse(FieldWeatherCache.isReady(c, marker))
  c:write(FieldWeatherCache.markerPath(), marker)
  Assert.isTrue(FieldWeatherCache.isReady(c, marker))
  Assert.isFalse(FieldWeatherCache.isReady(c, marker .. "-stale"))
end

function T.validation_rejects_incomplete_preset_range()
  local FieldWeatherCache = requireCache()
  local catalog = validCatalog()
  catalog.presets[13] = nil
  local ok, err = FieldWeatherCache.validateCatalog(catalog)
  Assert.isFalse(ok)
  Assert.notNil(err)
end

function T.validation_rejects_table_with_wrong_entry_count()
  local FieldWeatherCache = requireCache()
  local catalog = validCatalog()
  catalog.presets[1].table = { 0, 1, 2 }
  local ok = FieldWeatherCache.validateCatalog(catalog)
  Assert.isFalse(ok)
end

function T.validation_rejects_renderer_incompatible_preset_shape()
  local FieldWeatherCache = requireCache()
  local catalog = validCatalog()
  catalog.presets[1].enabled = "yes"
  local ok = FieldWeatherCache.validateCatalog(catalog)
  Assert.isFalse(ok)
end

function T.validation_rejects_unknown_rule_kind()
  local FieldWeatherCache = requireCache()
  local catalog = validCatalog()
  catalog.rules[1].kind = "unknown_kind"
  local ok = FieldWeatherCache.validateCatalog(catalog)
  Assert.isFalse(ok)
end

function T.validation_rejects_rule_missing_required_field()
  local FieldWeatherCache = requireCache()
  local catalog = validCatalog()
  catalog.rules[1].dates = nil
  local ok = FieldWeatherCache.validateCatalog(catalog)
  Assert.isFalse(ok)
end

function T.validation_rejects_catalog_whose_target_preset_is_absent()
  local FieldWeatherCache = requireCache()
  local catalog = validCatalog()
  catalog.presets[8] = nil
  local ok = FieldWeatherCache.validateCatalog(catalog)
  Assert.isFalse(ok)
end

function T.validation_requires_schema_exact_match()
  local FieldWeatherCache = requireCache()
  local catalog = validCatalog()
  catalog.schema = "g4-field-weather-v0"
  local ok = FieldWeatherCache.validateCatalog(catalog)
  Assert.isFalse(ok)
end

return { tests = T }
