-- Lightweight availability audit for the published derived cache. It checks
-- completion markers only; dependency freshness remains the cache builder's
-- responsibility when a developer explicitly rebuilds, and implementation
-- freshness belongs to the producer fingerprint.

local FieldActorCache = require("libs.assets.src.FieldActorCache")
local AudioCache = require("libs.assets.src.AudioCache")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldWeatherCache = require("libs.assets.src.FieldWeatherCache")

local DerivedCacheAudit = {}

local REQUIRED_MARKERS = {
  FieldActorCache.markerPath(),
  AudioCache.markerPath(),
  FieldCameraCache.markerPath(),
  FieldFontCache.markerPath(),
  FieldMessageCache.markerPath(),
  FieldUiAssetCache.markerPath(),
  FieldWeatherCache.markerPath(),
  ScriptCache.markerPath(),
}

---@param cacheFs CacheFs
---@return boolean, string|nil
function DerivedCacheAudit.isAvailable(cacheFs)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "DerivedCacheAudit requires a CacheFs-shaped object")
  for _, path in ipairs(REQUIRED_MARKERS) do
    if cacheFs:read(path) == nil then
      return false, "missing completion marker " .. path
    end
  end

  local world = cacheFs:loadLua(MapAssetCache.worldPath())
  if type(world) ~= "table" or type(world.maps) ~= "table" then
    return false, "missing world manifest"
  end
  for _, map in ipairs(world.maps) do
    if type(map) ~= "table" or type(map.id) ~= "number" or map.id < 0 or map.id % 1 ~= 0 then
      return false, "world manifest has an invalid map entry"
    end
    if cacheFs:read(MapAssetCache.mapDir(map.id) .. "/complete") == nil then
      return false, "map " .. map.id .. " has no completion marker"
    end
    if cacheFs:read(FieldMapDataCache.markerPath(map.id)) == nil then
      return false, "field map " .. map.id .. " has no completion marker"
    end
  end
  return true
end

return DerivedCacheAudit
