-- Static architecture guard: enforces the romdump boundary by scanning literal
-- require("...") strings across the libs packages (assets, codec, storage,
-- errors, math, engine), the game package (src and tests), and romdump/src
-- (production producers). Literal scanning is sufficient because the
-- repository requires modules by full repo-relative path; this is deliberately
-- not a general-purpose dependency analyzer.

local Assert = require("tests.support.Assert")

local T = {}

local BASE = love.filesystem.getSourceBaseDirectory()

-- The launcher/import UI is the sole sanctioned game -> romdump provisioning
-- dependency; every other game romdump require is a violation.
local GAME_ALLOWLIST = {
  ["game/src/game/App.lua"] = {
    ["romdump.src.source.GameVersion"] = true,
    ["romdump.src.source.RomImporter"] = true,
  },
  ["game/src/launcher/VersionSelectState.lua"] = {
    ["romdump.src.source.GameVersion"] = true,
  },
  -- The import screen renders importer status, so it consumes the importer's
  -- named state vocabulary.
  ["game/src/launcher/ImportState.lua"] = {
    ["romdump.src.source.RomImporter"] = true,
  },
  -- App's boot-wiring test stubs the same readiness seam App itself uses to
  -- cover the _bootExisting branches, which no other layer can (App requires
  -- a window; a real boot is ROM-gated acceptance territory).
  ["game/tests/app_state_test.lua"] = {
    ["romdump.src.source.RomImporter"] = true,
  },
}

local PACKAGE_ROOTS = {
  "libs/assets",
  "libs/codec",
  "libs/errors",
  "libs/storage",
  "libs/math",
  "libs/engine",
  "game",
  "romdump/src",
}

-- The producer side of the same boundary: romdump digests raw ROM bytes and
-- may depend on the domain libs (assets, codec, storage, errors, math) but
-- never on a libs runtime package. Digest compilers and the runtime engine
-- must both consume the same lower shared contracts, so a romdump -> engine
-- require points the dependency upward. libs.engine is the only libs runtime
-- package today; a future runtime libs package joins this list. The scan
-- covers romdump/src only: romdump tests legitimately compose compiler output
-- against engine consumers (round-trip pipeline tests), which is not
-- production composition.
local ROMDUMP_FORBIDDEN_LIBS = {
  "libs.engine.",
}

local SCRIPT_VALUE_FUNCTIONS = {
  "writeRef",
  "evaluateValue",
  "resolveIdOperand",
  "evaluateMessage",
  "evaluateCondition",
  "resolveActor",
  "requireActor",
  "actorExists",
}

-- Namespaces deleted by the boundary moves; none may reappear.
local FORBIDDEN_PREFIXES = {
  "libs.rom",
  "data.reference.hgss",
  "libs.assets.src.Hgss",
  "data.manifests.hgss",
  "data.manifests.field_cameras",
  "data.manifests.field_messages",
  "data.manifests.field_actors",
}

local scanned = nil

local function luaFilesUnder(root)
  -- stderr is discarded: a missing root surfaces as the empty-index assertion.
  local command = "find '" .. BASE .. "/" .. root .. "' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
  local prefix = BASE .. "/"
  local out = {}
  for line in pipe:lines() do
    assert(line:sub(1, #prefix) == prefix, "unexpected path outside the repository: " .. line)
    out[#out + 1] = line:sub(#prefix + 1)
  end
  pipe:close()
  assert(#out > 0, "package root indexed no Lua files: " .. root)
  return out
end

local function readFile(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local content = handle:read("*a")
  handle:close()
  return content
end

-- The two spellings the repository uses; anything else is a load error before
-- this test could run.
local REQUIRE_PAREN = 'require%s*%(%s*"([^"]+)"%s*%)'
local REQUIRE_BARE = 'require%s*"([^"]+)"'

local function requiredModules(content)
  local modules = {}
  for module in content:gmatch(REQUIRE_PAREN) do
    modules[#modules + 1] = module
  end
  for module in content:gmatch(REQUIRE_BARE) do
    modules[#modules + 1] = module
  end
  return modules
end

-- repo-relative file path -> list of required module names
local function scannedFiles()
  if scanned == nil then
    scanned = {}
    for _, root in ipairs(PACKAGE_ROOTS) do
      for _, file in ipairs(luaFilesUnder(root)) do
        scanned[file] = requiredModules(readFile(file))
      end
    end
  end
  return scanned
end

local function violationsFor(files, predicate)
  local violations = {}
  for file, modules in pairs(files) do
    for _, module in ipairs(modules) do
      if predicate(file, module) then
        violations[#violations + 1] = file .. " requires " .. module
      end
    end
  end
  return violations
end

local function importsRomdump(module)
  return module:sub(1, #"romdump.") == "romdump."
end

-- nil when there is nothing to report, so the assertion message stays
-- optional; Assert.isTrue accepts a nil message.
local function violationMessage(heading, violations)
  if #violations == 0 then
    return nil
  end
  return heading .. table.concat(violations, "\n")
end

function T.assets_and_engine_never_import_romdump()
  local violations = violationsFor(scannedFiles(), function(file, module)
    return file:sub(1, #"libs/") == "libs/" and importsRomdump(module)
  end)
  Assert.isTrue(#violations == 0, violationMessage("libs packages import romdump:\n", violations))
end

function T.game_imports_romdump_only_in_the_launcher_ui()
  local violations = violationsFor(scannedFiles(), function(file, module)
    if file:sub(1, #"game/") ~= "game/" or not importsRomdump(module) then
      return false
    end
    local allowed = GAME_ALLOWLIST[file]
    return not (allowed ~= nil and allowed[module])
  end)
  Assert.isTrue(#violations == 0, violationMessage("game imports romdump outside the launcher UI:\n", violations))
end

function T.removed_namespaces_do_not_reappear()
  local violations = violationsFor(scannedFiles(), function(_, module)
    for _, prefix in ipairs(FORBIDDEN_PREFIXES) do
      if module:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end)
  Assert.isTrue(#violations == 0, violationMessage("removed namespaces reappeared:\n", violations))
end

function T.romdump_never_imports_libs_engine()
  local violations = violationsFor(scannedFiles(), function(file, module)
    if file:sub(1, #"romdump/src/") ~= "romdump/src/" then
      return false
    end
    for _, prefix in ipairs(ROMDUMP_FORBIDDEN_LIBS) do
      if module:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end)
  Assert.isTrue(#violations == 0, violationMessage("romdump/src imports a libs runtime package:\n", violations))
end

function T.script_value_evaluation_exports_stay_on_runtime_values()
  local RuntimeValues = require("libs.engine.src.script.RuntimeValues")
  local Runtime = require("libs.engine.src.script.Runtime")

  for _, name in ipairs(SCRIPT_VALUE_FUNCTIONS) do
    Assert.equal(type(RuntimeValues[name]), "function", "RuntimeValues must own " .. name)
    Assert.isNil(Runtime[name], "Runtime must not re-export " .. name)
  end
end

function T.script_tasks_do_not_import_the_node_interpreter()
  local violations = violationsFor(scannedFiles(), function(file, module)
    return file:sub(1, #"libs/engine/src/script/tasks/") == "libs/engine/src/script/tasks/"
      and module == "libs.engine.src.script.Runtime"
  end)
  Assert.isTrue(#violations == 0, violationMessage("script tasks import the node interpreter:\n", violations))
end

return { tests = T }
