-- Atomic marker-last writer for the derived script class. Writes the
-- provenance record, the index, the coverage report, and one file per
-- translated script, readback-validates the index and every script file, and
-- only then publishes the completion marker. On any failure the whole class
-- is invalidated so a partial build never reads as complete.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")

local ScriptCacheWriter = {}

function ScriptCacheWriter.isReady(cacheFs, marker)
  return ScriptCache.isReady(cacheFs, marker)
end

-- A dependency-free JSON writer for the coverage record (LuaWriter encodes
-- Lua, not JSON). Strings escape control characters properly.
local function jsonValue(value)
  local ty = type(value)
  if ty == "nil" then
    return "null"
  end
  if ty == "boolean" then
    return value and "true" or "false"
  end
  if ty == "number" then
    return tostring(value)
  end
  if ty == "string" then
    local escaped = value:gsub('["\\\n\r\t\b\f]', {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
    })
    return '"' .. escaped .. '"'
  end
  if ty == "table" then
    -- A contiguous 1-based array becomes a JSON array; anything with
    -- non-array keys (including numeric-keyed hash tables like the opcode
    -- map) becomes an object with stringified keys.
    local isArray = true
    local maxKey = 0
    for key in pairs(value) do
      if type(key) ~= "number" then
        isArray = false
        break
      end
      if key > maxKey then
        maxKey = key
      end
    end
    if isArray and maxKey == #value then
      local parts = {}
      for i = 1, #value do
        parts[#parts + 1] = jsonValue(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = '"' .. tostring(key) .. '":' .. jsonValue(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

function ScriptCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.index and bundle.resources, "write requires a script bundle")
  assert(bundle.index.schema == ScriptCache.INDEX_SCHEMA, "bundle index schema mismatch")
  local ok, err = pcall(function()
    cacheFs:remove(ScriptCache.markerPath())
    cacheFs:writeLua(ScriptCache.provenancePath(), {
      schema = ScriptCache.PROVENANCE_SCHEMA,
      dependencies = bundle.dependencies,
    })
    cacheFs:writeLua(ScriptCache.indexPath(), bundle.index)
    cacheFs:write(ScriptCache.coverageJsonPath(), jsonValue(bundle.coverageRecord) .. "\n")
    cacheFs:write(
      ScriptCache.coverageMdPath(),
      require("romdump.src.digest.script.Coverage").markdown(bundle.coverageRecord)
    )
    local emitOpts = {
      sourcePath = "romfs/" .. bundle.dependencies.scrSeqNarc.path,
      commit = bundle.dependencies.versionRomSha1,
      game = bundle.index.version,
    }
    for _, entry in ipairs(bundle.resources) do
      local text = ScriptCompiler.emit(entry, emitOpts)
      cacheFs:write(ScriptCache.scriptPath(entry.id), text)
    end
    local readIndex = cacheFs:loadLua(ScriptCache.indexPath())
    if type(readIndex) ~= "table" or readIndex.schema ~= ScriptCache.INDEX_SCHEMA then
      Errors.raise(ScriptErrors.SCRIPT_CACHE_READBACK_FAILED, "index readback failed", {})
    end
    for _, entry in ipairs(bundle.index.resources) do
      local script = cacheFs:loadModule(ScriptCache.scriptPath(entry.id))
      if type(script) ~= "table" or script.kind ~= "field_script" or script.id ~= entry.id then
        Errors.raise(
          ScriptErrors.SCRIPT_CACHE_READBACK_FAILED,
          "script " .. entry.id .. " readback failed",
          { id = entry.id }
        )
      end
    end
    cacheFs:write(ScriptCache.markerPath(), bundle.marker)
  end)
  if ok then
    return true
  end
  ScriptCache.invalidate(cacheFs)
  error(err)
end

return ScriptCacheWriter
