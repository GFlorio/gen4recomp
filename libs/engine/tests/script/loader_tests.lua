-- ScriptLoader tests (the script override system): generated bases load from
-- the compiled script cache, checked-in overrides under
-- `data/scripts/overrides/<id>.lua` override the script with the same id (or
-- introduce it when no base exists), the override layer beats the generated
-- base, and malformed override files fail loudly instead of silently keeping
-- the base.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptLoader = require("libs.engine.src.script.ScriptLoader")
local LuaWriter = require("libs.codec.src.LuaWriter")

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
-- override files. `manifestText` overrides the derived manifest when the
-- test needs a malformed one.
local function overrideFs(files, manifestText)
  files = files or {}
  if manifestText == nil then
    local manifest = {}
    for name in pairs(files) do
      local id = name:match("^(.*)%.lua$")
      if id ~= nil then
        manifest[#manifest + 1] = id
      end
    end
    table.sort(manifest)
    manifestText = "return {\n"
    for _, id in ipairs(manifest) do
      manifestText = manifestText .. "  " .. string.format("%q", id) .. ",\n"
    end
    manifestText = manifestText .. "}\n"
  end
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

-- 2b. The override manifest is evaluated in the same restricted environment
-- as resource chunks: a manifest relying on a global must fail loudly
-- instead of loading through the ordinary global environment.
T["override manifest runs in the restricted environment"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.stop() } }\n',
  }, 'return { string.lower("ELMS_LAB.ELM") }\n')
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
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

-- A cache whose generated script fails validation (the shape the compiled
-- cache writer can never emit, but a hand-tampered file could).
local function invalidScriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua("data/generated/script/index.lua", {
    schema = "g4-script-index-v1",
    resources = { { id = "invalid.script" } },
  })
  cache:write(
    "data/generated/script/scripts/invalid.script.lua",
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "invalid.script", steps = { S.setVar { } } }\n'
  )
  return cache
end

-- 8. A lazy build decodes nothing until first use: no script file is read
-- at build time, and base() reads exactly its own file.
T["lazy build reads no script files until first use"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local cache = scriptCache()
  local originalRead = cache.backend.read
  local scriptReads = 0
  cache.backend.read = function(self, path)
    if path:find("data/generated/script/scripts/", 1, true) then
      scriptReads = scriptReads + 1
    end
    return originalRead(self, path)
  end
  local registry = ScriptLoader.buildRegistry(cache, overrideFs({}), requireShim, { lazy = true })
  Assert.equal(scriptReads, 0, "a lazy build must not read any script file")
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.equal(scriptReads, 1, "base() reads exactly its own file")
end

-- 8b. The lazy per-use validation policy: by default a generated script is
-- validated on first use, so invalid content fails at the access point.
T["lazy build validates generated content on first use"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim, { lazy = true })
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    registry:base("invalid.script")
  end)
end

-- 8c. validateGenerated=false skips validation on the lazy path (a keyed
-- snapshot already proved the corpus unchanged since the cache build
-- validated it); the identity check still applies.
T["lazy build without validation accepts invalid generated content"] = function()
  local Registry = require("libs.engine.src.script.Registry")
  local registry = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim, {
    lazy = true,
    validateGenerated = false,
  })
  Assert.notNil(registry:base("invalid.script"))
end

-- 8d. The eager path still validates generated content by default.
T["eager build validates generated content by default"] = function()
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim)
  end)
end

-- 8e. The lazy path never skips the checked-in override layer: overrides are
-- fully validated eagerly on every boot.
T["lazy build does not skip override validation"] = function()
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    ScriptLoader.buildRegistry(
      scriptCache(),
      overrideFs({
        ["bad.override.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "bad.override", steps = { S.setVar { } } }\n',
      }),
      requireShim,
      { lazy = true }
    )
  end)
end

return T
