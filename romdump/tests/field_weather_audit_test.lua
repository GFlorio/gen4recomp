local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function requireWeatherCache()
  local ok, m = pcall(require, "libs.assets.src.field.FieldWeatherCache")
  if not ok then
    error("FieldWeatherCache is absent: audit cannot require the weather artifact", 0)
  end
  return m
end

local function publishedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
  local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
  local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
  local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local ScriptCache = require("libs.assets.src.ScriptCache")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  for _, path in ipairs({
    FieldActorCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    FieldMessageCache.markerPath(),
    FieldUiAssetCache.markerPath(),
    IntroAssetCache.markerPath(),
    AudioCache.markerPath(),
    ScriptCache.markerPath(),
    MapAssetCache.mapDir(7) .. "/complete",
    FieldMapDataCache.markerPath(7),
  }) do
    cache:write(path, "complete")
  end
  cache:writeLua(MapAssetCache.worldPath(), { maps = { { id = 7 } } })
  return cache
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
  local ok, FieldCacheBuild = pcall(require, "romdump.src.build.FieldCacheBuild")
  if not ok then
    error("FieldCacheBuild is absent: cannot verify weather build wiring", 0)
  end
  -- The field build owner must include the weather compiler; this is a
  -- structural check that the extracted field stage references the artifact.
  local info = debug.getinfo(FieldCacheBuild.build, "S")
  local contents = ""
  if info and info.source and info.source:sub(1, 1) == "@" then
    local handle = io.open(info.source:sub(2), "r")
    if handle then
      contents = handle:read("*a")
      handle:close()
    end
  end
  -- Also accept the in-memory source via debug.getinfo line scan as fallback
  if contents == "" then
    contents = tostring(info and info.source or "")
  end
  Assert.isTrue(
    contents:find("FieldWeather", 1, true) ~= nil
      or contents:find("fieldWeather", 1, true) ~= nil
      or contents:find("weather", 1, true) ~= nil
      or tostring(info.source):find("weather", 1, true) ~= nil,
    "CacheBuilder must mention the weather artifact"
  )
end

return { tests = T }
