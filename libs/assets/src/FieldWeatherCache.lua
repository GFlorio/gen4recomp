-- Readiness, paths, and strict validation for the generated field-weather
-- class: the weather catalog carrying fourteen HGSS fog presets and the
-- ordered effective-weather rule descriptors. The manifest lives at
-- data/generated/field/weather/catalog.lua and a completion marker is
-- written last with the ROM SHA-1 and producer dependency hash. A weather
-- class is ready only when the marker matches exactly and the catalog
-- loads with the expected schema and passes strict validation (fourteen
-- presets, 32-entry tables, renderer-compatible fields, four ordered rules).
-- Paths are cache-relative; all IO goes through a CacheFs.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

local FieldWeatherCache = {}

---@class FieldWeatherCache.Preset
---@field enabled boolean
---@field color integer
---@field offset integer
---@field slope integer
---@field alpha integer
---@field table integer[]

---@class FieldWeatherCache.Catalog
---@field schema string
---@field presets table<integer, FieldWeatherCache.Preset>
---@field rules table[]

FieldWeatherCache.FORMAT = Contract.fieldWeather.cacheFormat
FieldWeatherCache.SCHEMA = Contract.fieldWeather.schema

local CATALOG_INVALID = "FIELD_WEATHER_CATALOG_INVALID"

local DATA_DIR = "data/generated/field/weather"

function FieldWeatherCache.dir()
  return DATA_DIR
end

function FieldWeatherCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end

function FieldWeatherCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function FieldWeatherCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldWeatherCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldWeatherCache.FORMAT, romSha1, depHash)
end

-- Internal preset shape check used by validateCatalog (nil, err on failure).
---@param id integer
---@param preset unknown
---@return boolean, Errors.Error?
local function validatePreset(id, preset)
  if type(preset) ~= "table" then
    return false, Errors.new(CATALOG_INVALID, "preset " .. id .. " must be a table", { id = id })
  end
  if type(preset.enabled) ~= "boolean" then
    return false, Errors.new(CATALOG_INVALID, "preset " .. id .. " enabled must be a boolean", { id = id })
  end
  for _, field in ipairs({ "color", "offset", "slope", "alpha" }) do
    local v = preset[field] ---@type number
    if type(v) ~= "number" or v ~= math.floor(v) then
      return false,
        Errors.new(
          CATALOG_INVALID,
          "preset " .. id .. " " .. field .. " must be an integer",
          { id = id, field = field }
        )
    end
  end
  if type(preset.table) ~= "table" then
    return false, Errors.new(CATALOG_INVALID, "preset " .. id .. " table must be a table", { id = id })
  end
  if #preset.table ~= 32 then
    return false,
      Errors.new(CATALOG_INVALID, "preset " .. id .. " table must have exactly 32 entries", {
        id = id,
        count = #preset.table,
      })
  end
  for i = 1, 32 do
    local v = preset.table[i]
    if type(v) ~= "number" or v ~= math.floor(v) or v < 0 or v > 255 then
      return false,
        Errors.new(CATALOG_INVALID, "preset " .. id .. " table[" .. i .. "] must be an integer 0..255", {
          id = id,
          index = i,
        })
    end
  end
  return true
end

local function validateRuleTarget(rule, index, presets)
  if
    type(rule.weatherId) ~= "number"
    or rule.weatherId ~= math.floor(rule.weatherId)
    or rule.weatherId < 0
    or rule.weatherId > 13
  then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " weatherId must be an integer 0..13", { index = index })
  end
  if not presets[rule.weatherId] then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " target weatherId " .. rule.weatherId .. " has no preset", {
        index = index,
        weatherId = rule.weatherId,
      })
  end
  return true
end

local function validateCalendarMapRule(rule, index)
  if type(rule.mapId) ~= "number" or rule.mapId ~= math.floor(rule.mapId) or rule.mapId < 0 then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " mapId must be a non-negative integer", { index = index })
  end
  if rule.requireNoPenalty ~= true then
    return false, Errors.new(CATALOG_INVALID, "rule " .. index .. " requireNoPenalty must be true", { index = index })
  end
  if type(rule.dates) ~= "table" or #rule.dates == 0 then
    return false, Errors.new(CATALOG_INVALID, "rule " .. index .. " dates must be a non-empty table", { index = index })
  end
  local dates = rule.dates ---@type table[]
  for j, entry in ipairs(dates) do
    local date = entry ---@type table
    if type(date) ~= "table" or type(date.month) ~= "number" or type(date.day) ~= "number" then
      return false,
        Errors.new(CATALOG_INVALID, "rule " .. index .. " date " .. j .. " must have month and day", {
          index = index,
          entry = j,
        })
    end
    if date.month ~= math.floor(date.month) or date.month < 1 or date.month > 12 then
      return false,
        Errors.new(CATALOG_INVALID, "rule " .. index .. " date " .. j .. " month must be 1..12", {
          index = index,
          entry = j,
        })
    end
    if date.day ~= math.floor(date.day) or date.day < 1 or date.day > 31 then
      return false,
        Errors.new(CATALOG_INVALID, "rule " .. index .. " date " .. j .. " day must be 1..31", {
          index = index,
          entry = j,
        })
    end
  end
  return true
end

local function validateMapVarRule(rule, index)
  if type(rule.mapId) ~= "number" or rule.mapId ~= math.floor(rule.mapId) or rule.mapId < 0 then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " mapId must be a non-negative integer", { index = index })
  end
  if type(rule.varId) ~= "number" or rule.varId ~= math.floor(rule.varId) or rule.varId < 0 or rule.varId > 0xFFFF then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " varId must be an integer 0..0xFFFF", { index = index })
  end
  if type(rule.value) ~= "number" or rule.value ~= math.floor(rule.value) or rule.value < 0 or rule.value > 0xFFFF then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " value must be an integer 0..0xFFFF", { index = index })
  end
  return true
end

local function validateWeatherFlagRule(rule, index, presets)
  if
    type(rule.fromWeatherId) ~= "number"
    or rule.fromWeatherId ~= math.floor(rule.fromWeatherId)
    or rule.fromWeatherId < 0
    or rule.fromWeatherId > 13
  then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " fromWeatherId must be an integer 0..13", {
        index = index,
      })
  end
  if not presets[rule.fromWeatherId] then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " fromWeatherId " .. rule.fromWeatherId .. " has no preset", {
        index = index,
        fromWeatherId = rule.fromWeatherId,
      })
  end
  if
    type(rule.flagId) ~= "number"
    or rule.flagId ~= math.floor(rule.flagId)
    or rule.flagId < 0
    or rule.flagId > 0xFFFF
  then
    return false,
      Errors.new(CATALOG_INVALID, "rule " .. index .. " flagId must be an integer 0..0xFFFF", { index = index })
  end
  return true
end

---@param rule table
---@param index integer
---@param presets table<integer, FieldWeatherCache.Preset>
---@return boolean, Errors.Error?
local function validateRule(rule, index, presets)
  if type(rule) ~= "table" then
    return false, Errors.new(CATALOG_INVALID, "rule " .. index .. " must be a table", { index = index })
  end
  local kind = rule.kind ---@type string
  if kind ~= "calendar_map_override" and kind ~= "map_var_equals" and kind ~= "weather_flag_override" then
    return false,
      Errors.new(
        CATALOG_INVALID,
        "rule " .. index .. " has unknown kind " .. tostring(kind),
        { index = index, kind = kind }
      )
  end
  local targetOk, targetError = validateRuleTarget(rule, index, presets)
  if not targetOk then
    return false, targetError
  end
  if kind == "calendar_map_override" then
    return validateCalendarMapRule(rule, index)
  elseif kind == "map_var_equals" then
    return validateMapVarRule(rule, index)
  elseif kind == "weather_flag_override" then
    return validateWeatherFlagRule(rule, index, presets)
  end
  return true
end

-- Strict catalog validation: shared by the writer's readback and by runtime
-- loading. Returns true on success, false, err otherwise.
---@param catalog unknown
---@return boolean, Errors.Error?
function FieldWeatherCache.validateCatalog(catalog)
  if type(catalog) ~= "table" then
    return false, Errors.new(CATALOG_INVALID, "catalog is not a table", {})
  end
  if catalog.schema ~= FieldWeatherCache.SCHEMA then
    return false,
      Errors.new(CATALOG_INVALID, "catalog schema mismatch", {
        schema = catalog.schema,
        expected = FieldWeatherCache.SCHEMA,
      })
  end
  if type(catalog.presets) ~= "table" then
    return false, Errors.new(CATALOG_INVALID, "catalog presets must be a table", {})
  end
  -- presets exactly 0..13 inclusive.
  local count = 0
  for _ in pairs(catalog.presets) do
    count = count + 1
  end
  if count ~= 14 then
    return false, Errors.new(CATALOG_INVALID, "catalog must have exactly 14 presets (0..13)", { count = count })
  end
  for id = 0, 13 do
    local ok, err = validatePreset(id, catalog.presets[id])
    if not ok then
      return false, err
    end
  end
  if type(catalog.rules) ~= "table" then
    return false, Errors.new(CATALOG_INVALID, "catalog rules must be a table", {})
  end
  if #catalog.rules ~= 4 then
    return false, Errors.new(CATALOG_INVALID, "catalog must have exactly 4 rules", { count = #catalog.rules })
  end
  local expectedKinds = { ---@type string[]
    "calendar_map_override",
    "map_var_equals",
    "weather_flag_override",
    "weather_flag_override",
  }
  for i, rule in ipairs(catalog.rules) do
    if rule.kind ~= expectedKinds[i] then
      return false,
        Errors.new(
          CATALOG_INVALID,
          "rule " .. i .. " expected kind " .. expectedKinds[i] .. ", got " .. tostring(rule.kind),
          {
            index = i,
            expected = expectedKinds[i],
            got = rule.kind,
          }
        )
    end
    local ok, err = validateRule(rule, i, catalog.presets)
    if not ok then
      return false, err
    end
  end
  return true
end

-- Convenience alias expected by some call sites.
FieldWeatherCache.validate = FieldWeatherCache.validateCatalog

function FieldWeatherCache.hasCache(cacheFs)
  local catalog = cacheFs:loadLua(FieldWeatherCache.catalogPath()) ---@type table?
  if type(catalog) ~= "table" then
    return false
  end
  return FieldWeatherCache.validateCatalog(catalog) == true
end

-- Readiness check matching nearby caches: marker must match exactly and the
-- catalog must exist and pass validation.
function FieldWeatherCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldWeatherCache.markerPath()) ~= expectedMarker then
    return false
  end
  local catalog = cacheFs:loadLua(FieldWeatherCache.catalogPath()) ---@type table?
  if type(catalog) ~= "table" then
    return false
  end
  local ok = FieldWeatherCache.validateCatalog(catalog)
  if not ok then
    return false
  end
  return true
end

return FieldWeatherCache
