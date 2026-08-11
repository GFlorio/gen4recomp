-- Lightweight availability audit for the published derived cache. It checks
-- completion markers only; dependency freshness remains the cache builder's
-- responsibility when a developer explicitly rebuilds.

local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local FieldCameraCacheWriter = require("romdump.src.digest.FieldCameraCacheWriter")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")

local DerivedCacheAudit = {}

local REQUIRED_MARKERS = {
  FieldActorCache.markerPath(),
  FieldCameraCacheWriter.markerPath(),
  FieldFontCache.markerPath(),
  FieldMessageCache.markerPath(),
  ScriptCache.markerPath(),
}

local function scriptCompilerIsCurrent(cacheFs)
  local provenance = cacheFs:loadLua(ScriptCache.provenancePath())
  local dependencies = provenance and provenance.dependencies
  return type(dependencies) == "table" and dependencies.compilerVersion == ScriptCompiler.COMPILER_VERSION
end

---@param cacheFs CacheFs
---@return boolean, string|nil
function DerivedCacheAudit.isAvailable(cacheFs)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "DerivedCacheAudit requires a CacheFs-shaped object")
  for _, path in ipairs(REQUIRED_MARKERS) do
    if cacheFs:read(path) == nil then
      return false, "missing completion marker " .. path
    end
  end
  if not scriptCompilerIsCurrent(cacheFs) then
    return false, "script cache compiler is not " .. ScriptCompiler.COMPILER_VERSION
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
