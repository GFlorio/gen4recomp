-- Compiles the normalized field-weather catalog: fourteen HGSS fog presets
-- resolved through HgssFieldFog and the four ordered effective-weather
-- override rules whose numeric IDs are derived from checked-in HGSS
-- references (MapCatalog / FieldScriptSymbols). The runtime consumes only
-- the generated catalog; this module never leaks into engine/game.
-- Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local HgssFieldFog = require("romdump.src.digest.HgssFieldFog")
local FieldWeatherCache = require("libs.assets.src.FieldWeatherCache")
local Hashing = require("romdump.src.digest.Hashing")

local FieldWeatherCompiler = {}

FieldWeatherCompiler.ERROR = {
  SOURCE_INVALID = "FIELD_WEATHER_SOURCE_INVALID",
}

-- The eight Diamond Dust calendar dates (HGSS src/field_system_rtc_weather.c).
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

local function resolveMapId(symbol, fallback)
  local ok, MapCatalog = pcall(require, "romdump.src.digest.MapCatalog")
  if ok and MapCatalog and MapCatalog.idForSymbol then
    local id = MapCatalog.idForSymbol(symbol)
    if id ~= nil then
      return id
    end
  end
  return fallback
end

local function resolveFlag(name, fallback)
  local ok, Symbols = pcall(require, "libs.assets.src.FieldScriptSymbols")
  if ok and Symbols and Symbols.flagsByName and Symbols.flagsByName[name] ~= nil then
    return Symbols.flagsByName[name]
  end
  return fallback
end

local function buildCatalog()
  local presets = {}
  for id = 0, 13 do
    local full = HgssFieldFog.resolve(id)
    presets[id] = HgssFieldFog.runtimePreset(full)
  end

  local mtSilverSummit = resolveMapId("MAP_MOUNT_SILVER_CAVE_SUMMIT", 465)
  local lakeOfRage = resolveMapId("MAP_LAKE_OF_RAGE", 88)
  local flagDefog = resolveFlag("FLAG_SYS_DEFOG", 2420)
  local flagFlash = resolveFlag("FLAG_SYS_FLASH", 2419)

  local rules = {
    {
      kind = "calendar_map_override",
      mapId = mtSilverSummit,
      weatherId = 8,
      requireNoPenalty = true,
      dates = DIAMOND_DUST_DATES,
    },
    {
      kind = "map_var_equals",
      mapId = lakeOfRage,
      varId = 0x4037,
      value = 0xF229,
      weatherId = 0,
    },
    {
      kind = "weather_flag_override",
      fromWeatherId = 9,
      flagId = flagDefog,
      weatherId = 0,
    },
    {
      kind = "weather_flag_override",
      fromWeatherId = 11,
      flagId = flagFlash,
      weatherId = 12,
    },
  }

  local catalog = {
    schema = FieldWeatherCache.SCHEMA,
    presets = presets,
    rules = rules,
  }

  local ok, err = FieldWeatherCache.validateCatalog(catalog)
  if not ok then
    Errors.raise(FieldWeatherCompiler.ERROR.SOURCE_INVALID, "field weather catalog is invalid", {
      cause = err and err.message or tostring(err),
    })
  end
  return catalog
end

local function _compile(romFs, sha1hex, hashLua)
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua

  local catalog = buildCatalog()

  local romSha1 = "rom-sha"
  if romFs and romFs.metadata then
    local ok, meta = pcall(function()
      return romFs:metadata()
    end)
    if ok and meta and type(meta.sha1) == "string" then
      romSha1 = meta.sha1
    end
  end

  local depHash = hashLua(catalog)
  local marker = FieldWeatherCache.FORMAT .. ":" .. romSha1 .. ":" .. depHash

  local provenance = {
    schema = "g4-field-weather-provenance-v1",
    dependencies = {
      { name = "HgssFieldFog", sha1 = sha1hex("HgssFieldFog-v1") },
      { name = "catalog", sha1 = depHash },
    },
  }

  return {
    catalog = catalog,
    provenance = provenance,
    marker = marker,
    romSha1 = romSha1,
    depHash = depHash,
  }
end

function FieldWeatherCompiler.compile(romFs, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, sha1hex, hashLua)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result, 0)
end

return FieldWeatherCompiler
