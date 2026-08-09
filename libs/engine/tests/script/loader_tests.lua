-- ScriptLoader tests (the script override system): generated bases load from
-- the compiled script cache, checked-in overrides under
-- `data/scripts/overrides/<id>.lua` override the script with the same id (or
-- introduce it when no base exists), the override layer beats the generated
-- base, and malformed override files fail loudly instead of silently keeping
-- the base.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptLoader = require("libs.engine.src.script.ScriptLoader")
local LuaWriter = require("libs.rom.src.LuaWriter")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.equal(err.code, code)
end

-- A fake cache carrying a two-resource script class (the index schema and
-- script file shapes match the compiled cache writer).
local function scriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua("data/generated/script/index.lua", {
    schema = "g4-script-index-v1",
    resources = {
      { id = "vanilla.hgss.scr_seq.0842.script_001" },
      { id = "new_bark.lab_sign" },
    },
  })
  cache:write(
    "data/generated/script/scripts/vanilla.hgss.scr_seq.0842.script_001.lua",
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "vanilla.hgss.scr_seq.0842.script_001", steps = { S.stop() } }\n'
  )
  cache:write(
    "data/generated/script/scripts/new_bark.lab_sign.lua",
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.say { message = "msg.hgss.0543.00097" }, S.stop() } }\n'
  )
  return cache
end

-- A read-shaped filesystem for the override tree: the manifest and the
-- override files.
local function overrideFs(files)
  files = files or {}
  local manifest = {}
  for name in pairs(files) do
    local id = name:match("^(.*)%.lua$")
    if id ~= nil then
      manifest[#manifest + 1] = id
    end
  end
  table.sort(manifest)
  local manifestText = "return {\n"
  for _, id in ipairs(manifest) do
    manifestText = manifestText .. "  " .. string.format("%q", id) .. ",\n"
  end
  manifestText = manifestText .. "}\n"
  return {
    read = function(self, path)
      if path == ScriptLoader.OVERRIDE_MANIFEST then
        return manifestText
      end
      for name, content in pairs(files) do
        if path == "data/scripts/overrides/" .. name then
          return content
        end
      end
      return nil
    end,
  }
end

local function requireShim(name)
  if name == "gen4.script" then
    return require("gen4.script")
  end
  error("unexpected require in override chunk: " .. name)
end

-- 1. Generated bases install from the cache index and files.
T["generated bases load from the script cache"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.notNil(registry:base("vanilla.hgss.scr_seq.0842.script_001"))
  Assert.isNil(registry:base("vanilla.hgss.scr_seq.0842.script_002"))
end

-- 2. An override file replaces the script with the same id, and beats the
-- generated base.
T["override replaces the base script with the same id"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  local fs = overrideFs({
    ["new_bark.lab_sign.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n',
  })
  local ids = ScriptLoader.installOverrides(registry, fs, requireShim)
  Assert.deepEqual(ids, { "new_bark.lab_sign" })
  local base = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(base.steps[1].op, "noop", "the override wins over the generated base")
end

-- 3. An override may introduce an id with no generated base (the curated
-- Elm replacement pattern).
T["override introduces an id without a base"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.stop() } }\n',
  })
  ScriptLoader.installOverrides(registry, fs, requireShim)
  Assert.notNil(registry:base("elms_lab.elm"))
end

-- 4. An override whose file id disagrees with the resource id fails loudly.
T["override id mismatch is a hard error"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "other.id", steps = { S.stop() } }\n',
  })
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
end

-- 5. An override that fails validation fails loudly.
T["invalid override fails loudly"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.setVar {  } } }\n',
  })
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
end

-- 6. buildRegistry composes the full pipeline and the effective composition
-- resolves the override.
T["buildRegistry composes the override"] = function()
  local Composition = require("libs.engine.src.script.Composition")
  local registry = ScriptLoader.buildRegistry(
    scriptCache(),
    overrideFs({
      ["new_bark.lab_sign.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n',
    }),
    requireShim
  )
  local composition = Composition.new(registry)
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(effective.entries[1].operation, "base")
  Assert.equal(effective.entries[1].graph.nodes[effective.entries[1].graph.entry].op, "noop")
end

-- 7. buildRegistry passes the injected require through to the generated
-- cache files too: a require the allowlist would reject is observable.
T["buildRegistry injects require for generated files"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local calls = {}
  local injected = function(name)
    calls[#calls + 1] = name
    return requireShim(name)
  end
  local registry = ScriptLoader.buildRegistry(scriptCache(), overrideFs({}), injected)
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.isTrue(#calls > 0, "the injected require ran for the generated files")
end

return T
