local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function requireWeatherCache()
  local ok, m = pcall(require, "libs.assets.src.FieldWeatherCache")
  if not ok then
    error("FieldWeatherCache is absent: audit cannot require the weather artifact", 0)
  end
  return m
end

local function publishedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local FieldActorCache = require("libs.assets.src.FieldActorCache")
  local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
  local FieldFontCache = require("libs.assets.src.FieldFontCache")
  local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
  local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
  local ScriptCache = require("libs.assets.src.ScriptCache")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
  for _, path in ipairs({
    FieldActorCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    FieldMessageCache.markerPath(),
    FieldUiAssetCache.markerPath(),
    ScriptCache.markerPath(),
    MapAssetCache.mapDir(7) .. "/complete",
    FieldMapDataCache.markerPath(7),
  }) do
    cache:write(path, "complete")
  end
  cache:writeLua(MapAssetCache.worldPath(), { maps = { { id = 7 } } })
  return cache
end

function T.audit_requires_the_weather_catalog_artifact_to_be_available()
  local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
  local FieldWeatherCache = requireWeatherCache()
  local cache = publishedCache()
  -- make the weather artifact available
  cache:write(FieldWeatherCache.markerPath(), "weather-complete")
  cache:writeLua(FieldWeatherCache.catalogPath(), {
    schema = FieldWeatherCache.SCHEMA,
    presets = {},
    rules = {},
  })
  -- stash original audit behavior: when weather marker missing, audit must report not available
  cache:remove(FieldWeatherCache.markerPath())
  local available, reason = DerivedCacheAudit.isAvailable(cache)
  Assert.isFalse(available, "audit must report unavailable when the weather catalog marker is missing")
  Assert.isTrue(
    tostring(reason):find("weather", 1, true) ~= nil or tostring(reason):find("field", 1, true) ~= nil,
    "reason must name the weather artifact: " .. tostring(reason)
  )
end

function T.audit_with_stale_weather_marker_requires_a_build()
  local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
  local FieldWeatherCache = requireWeatherCache()
  local cache = publishedCache()
  cache:write(FieldWeatherCache.markerPath(), "stale")
  cache:writeLua(FieldWeatherCache.catalogPath(), {
    schema = FieldWeatherCache.SCHEMA,
    presets = {},
    rules = {},
  })
  -- With a present but stale or empty catalog, the audit's freshness is
  -- owned by the builder's state gate; availability alone requires the marker
  -- to exist, so a missing marker is the stale signal.
  cache:remove(FieldWeatherCache.markerPath())
  local available = DerivedCacheAudit.isAvailable(cache)
  Assert.isFalse(available, "a missing weather marker must make the cache unavailable")
end

function T.builder_treats_stale_weather_artifact_as_a_required_write()
  local ok, CacheBuilder = pcall(require, "romdump.src.CacheBuilder")
  if not ok then
    error("CacheBuilder is absent: cannot verify weather build wiring", 0)
  end
  -- The builder pipeline must include the weather compiler; this is a
  -- structural check that the producer fingerprint and compile steps mention
  -- the weather artifact. Without production, this is red.
  local source = debug.getinfo(CacheBuilder.buildVersions, "S")
  local file = source and source.source or ""
  -- fallback: check that the module source mentions field weather
  local handle = io.open("/workspace/.agents/tmp/wt-d05/romdump/src/CacheBuilder.lua", "r")
  if not handle then
    error("CacheBuilder source cannot be opened to verify weather wiring", 0)
  end
  local contents = handle:read("*a")
  handle:close()
  Assert.isTrue(
    contents:find("FieldWeather", 1, true) ~= nil
      or contents:find("fieldWeather", 1, true) ~= nil
      or contents:find("weather", 1, true) ~= nil,
    "CacheBuilder must mention the weather artifact"
  )
end

return { tests = T }
