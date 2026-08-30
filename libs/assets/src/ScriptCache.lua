-- Readiness and paths for the derived script cache. The translated script
-- corpus is one of the independently rebuildable derived classes (map
-- geometry, actor visuals, messages/font, scripts): changing the script
-- translator must not disturb the raw ROM dump or any compiled map.
-- The class is ready only when the completion marker matches exactly and
-- every indexed script file is present, so a partial build never reads as
-- complete. Paths are cache-relative; all IO goes through a CacheFs.

local ScriptCache = {}

---@class ScriptCache.Index
---@field schema string
---@field resources table[]

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

ScriptCache.FORMAT = Contract.scripts.cacheFormat
ScriptCache.INDEX_SCHEMA = Contract.scripts.indexSchema
ScriptCache.PROVENANCE_SCHEMA = Contract.scripts.provenanceSchema

local DATA_DIR = "data/generated/script"

function ScriptCache.dir()
  return DATA_DIR
end
function ScriptCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function ScriptCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function ScriptCache.markerPath()
  return DATA_DIR .. "/complete"
end
function ScriptCache.coverageJsonPath()
  return DATA_DIR .. "/coverage.json"
end
function ScriptCache.coverageMdPath()
  return DATA_DIR .. "/coverage.md"
end

function ScriptCache.scriptPath(id)
  return string.format("%s/scripts/%s.lua", DATA_DIR, id)
end

function ScriptCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", ScriptCache.FORMAT, romSha1, depHash)
end

-- True only if the marker is exact, the index loads with the expected schema,
-- resources is the required array of entries, and every indexed script's file
-- loads as a field_script resource whose id matches its index entry.
function ScriptCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(ScriptCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(ScriptCache.indexPath()) ---@type table?
  if type(index) ~= "table" or index.schema ~= ScriptCache.INDEX_SCHEMA then
    return false
  end
  ---@cast index ScriptCache.Index
  if not Validate.isArray(index.resources) then
    return false
  end
  for _, entry in ipairs(index.resources) do
    if type(entry) ~= "table" or type(entry.id) ~= "string" or entry.id == "" then
      return false
    end
    local script = cacheFs:loadModule(ScriptCache.scriptPath(entry.id)) ---@type table?
    if type(script) ~= "table" or script.kind ~= "field_script" or script.id ~= entry.id then
      return false
    end
  end
  return true
end

return ScriptCache
