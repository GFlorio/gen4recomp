-- Script content loader for the game (the override system): installs the
-- generated transcript bases from the compiled script cache, then every
-- checked-in override under `data/scripts/overrides/` (a file named
-- `<script-id>.lua` overrides the script with that id, or introduces the id
-- when no base exists, as with the curated Elm replacement). Override files
-- are ordinary `return S.script { ... }` modules executed in a restricted
-- environment; the returned resource must carry the exact id of its file and
-- must validate in strict mode. The filesystem is injected (`getDirectoryItems`
-- + `read`), so the loader is testable headless; the game passes
-- love.filesystem after mounting the repo `data` directory. Pure domain
-- module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local Validator = require("libs.engine.src.script.Validator")

local ScriptLoader = {}

ScriptLoader.OVERRIDES_DIR = "data/scripts/overrides"

-- Load one Lua resource chunk (`return S.script { ... }`) in a restricted
-- environment that only provides `require`, so generated and override
-- modules can import gen4.script and nothing else.
---@param content string
---@param chunkName string
---@param requireFn function
---@return table resource
local function loadResourceChunk(content, chunkName, requireFn)
  local chunk, loadErr = loadstring(content, chunkName)
  if not chunk then
    Errors.raise(
      ScriptErrors.SCRIPT_HOT_RELOAD_FAILED,
      "script module does not parse: " .. tostring(loadErr),
      { path = chunkName }
    )
  end
  local env = { require = requireFn } --[[@as table]]
  setfenv(chunk, env)
  local ok, resource = pcall(chunk)
  if not ok then
    Errors.raise(
      ScriptErrors.SCRIPT_HOT_RELOAD_FAILED,
      "script module failed to load: " .. tostring(resource),
      { path = chunkName }
    )
  end
  if type(resource) ~= "table" then
    Errors.raise(
      ScriptErrors.SCRIPT_HOT_RELOAD_FAILED,
      "script module must return a resource table",
      { path = chunkName }
    )
  end
  return resource
end

-- Load every generated base from the compiled script cache: the index lists
-- the resources and each file is one `S.script` resource. A missing or
-- invalid base is a hard load error (the cache readiness check already gates
-- the build, so a mismatch here is a real fault).
---@param registry table Registry
---@param cacheFs table CacheFs-shaped
---@param requireFn fun(name: string): any
function ScriptLoader.installGenerated(registry, cacheFs, requireFn)
  requireFn = requireFn or function(name)
    return require(name)
  end
  local index, indexErr = cacheFs:loadLua(ScriptCache.indexPath())
  if not index then
    Errors.raise(
      ScriptErrors.SCRIPT_CACHE_INDEX_MISSING,
      "script cache index is unavailable: " .. tostring(indexErr and indexErr.message or "?"),
      { path = ScriptCache.indexPath(), cause = indexErr and indexErr.context or nil }
    )
  end
  if type(index) ~= "table" or index.schema ~= ScriptCache.INDEX_SCHEMA then
    Errors.raise(
      ScriptErrors.SCRIPT_CACHE_INDEX_MISSING,
      "script cache index has an unknown schema",
      { path = ScriptCache.indexPath(), schema = index and index.schema or nil }
    )
  end
  for _, entry in ipairs(index.resources or {}) do
    assert(type(entry.id) == "string" and entry.id ~= "", "script cache index entry id required")
    local content = cacheFs:read(ScriptCache.scriptPath(entry.id))
    if content == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_CACHE_SCRIPT_MISSING,
        "script cache resource is unavailable",
        { scriptId = entry.id, path = ScriptCache.scriptPath(entry.id) }
      )
    end
    local resource = loadResourceChunk(content --[[@as string]], ScriptCache.scriptPath(entry.id), requireFn)
    if resource.id ~= entry.id then
      Errors.raise(
        ScriptErrors.SCRIPT_CACHE_SCRIPT_INVALID,
        "script cache resource does not match its index entry",
        { scriptId = entry.id, resourceId = resource.id }
      )
    end
    local ok, validateErr = Validator.validate(resource)
    if not ok then
      Errors.raise(
        validateErr and validateErr.code or ScriptErrors.SCRIPT_SCHEMA_INVALID,
        "generated script fails validation: " .. tostring(validateErr and validateErr.message or "?"),
        { scriptId = entry.id, cause = validateErr and validateErr.context or nil }
      )
    end
    registry:installBase(entry.id, resource, "generated")
  end
end

-- Load one override file: `<id>.lua` returning an S.script resource whose id
-- must equal the file-derived id. Returns the resource.
---@param id string
---@param content string
---@param requireFn function
---@return table resource
function ScriptLoader.loadOverride(id, content, requireFn)
  local resource = loadResourceChunk(content, ScriptLoader.OVERRIDES_DIR .. "/" .. id .. ".lua", requireFn)
  if resource.id ~= id then
    Errors.raise(
      ScriptErrors.SCRIPT_HOT_RELOAD_FAILED,
      "override file " .. id .. ".lua defines script " .. tostring(resource.id),
      { scriptId = id, resourceId = resource.id }
    )
  end
  local okValidate, validateErr = Validator.validate(resource)
  if not okValidate then
    Errors.raise(
      validateErr and validateErr.code or ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "override fails validation: " .. tostring(validateErr and validateErr.message or "?"),
      { scriptId = id, cause = validateErr and validateErr.context or nil }
    )
  end
  return resource
end

-- Install every override from a directory-shaped filesystem. Files are
-- `data/scripts/overrides/<id>.lua`; the id is the basename without the
-- `.lua` suffix. Returns the ids installed, sorted.
---@param registry table Registry
---@param fs table { getDirectoryItems(path): string[], read(path): string? }
---@param requireFn fun(name: string): any
---@return string[]
function ScriptLoader.installOverrides(registry, fs, requireFn)
  requireFn = requireFn or function(name)
    return require(name)
  end
  local items = fs:getDirectoryItems(ScriptLoader.OVERRIDES_DIR) or {}
  table.sort(items)
  local ids = {}
  for _, name in ipairs(items) do
    local id = name:match("^(.*)%.lua$")
    if id ~= nil and id ~= "" then
      local path = ScriptLoader.OVERRIDES_DIR .. "/" .. name
      local content = fs:read(path)
      if content == nil then
        Errors.raise(ScriptErrors.SCRIPT_HOT_RELOAD_FAILED, "override file is unreadable: " .. path, { scriptId = id })
      end
      local resource = ScriptLoader.loadOverride(id, content --[[@as string]], requireFn)
      registry:installBase(id, resource, "override")
      ids[#ids + 1] = id
    end
  end
  return ids
end

-- Build a registry from the script cache plus the override directory. `fs`
-- must expose the mounted repo `data/scripts/overrides` directory; the game
-- passes love.filesystem after mounting the repo data tree.
---@param cacheFs table CacheFs-shaped
---@param fs table directory-shaped filesystem for data/scripts/overrides
---@param requireFn function
---@return table registry
function ScriptLoader.buildRegistry(cacheFs, fs, requireFn)
  local Registry = require("libs.engine.src.script.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, cacheFs)
  ScriptLoader.installOverrides(registry, fs, requireFn)
  return registry
end

return ScriptLoader
