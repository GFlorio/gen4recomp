-- Static architecture guard: enforces the romdump boundary by scanning literal
-- require("...") strings across the library packages, the game package (src and
-- tests), and romdump/src (production producers). Literal scanning is
-- sufficient because the repository requires modules by full repo-relative
-- path; this is deliberately not a general-purpose dependency analyzer.

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
  "libs/nds",
  "libs/script",
  "libs/hgss",
  "game",
  "romdump/src",
}

local TARGET_PACKAGE_ROOTS = {
  ["libs/nds"] = true,
  ["libs/script"] = true,
  ["libs/hgss"] = true,
}

local OPTIONAL_PACKAGE_ROOTS = {
  ["libs/hgss/src/field"] = true,
}

-- The producer side of the same boundary: romdump digests raw ROM bytes and
-- may depend on lower shared packages. The scan covers romdump/src only:
-- romdump tests legitimately compose compiler output against runtime consumers,
-- which is not production composition.
local ROMDUMP_FORBIDDEN_LIBS = {}

-- NDS format and semantic code is reusable platform logic. It may consume
-- foundations only; project assets, runtime packages, application policy, and
-- ROM producers stay above it.
local NDS_FORBIDDEN_LIBS = {
  "libs.assets.",
  "libs.script.",
  "libs.hgss.",
  "game.",
  "romdump.",
}

local NDS_SOUND_FORBIDDEN_LIBS = {
  "libs.assets.",
  "libs.hgss.",
  "libs.script.",
  "game.",
  "romdump.",
}

local HGSS_FIELD_FORBIDDEN_LIBS = { "game.", "romdump." }

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
  -- Guidance-only and not-yet-created target package roots are valid during
  -- migration. Existing roots still fail loudly when they index no Lua files.
  -- stderr is discarded because an absent target root contributes no files.
  local command = "find '" .. BASE .. "/" .. root .. "' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
  local prefix = BASE .. "/"
  local out = {}
  for line in pipe:lines() do
    assert(line:sub(1, #prefix) == prefix, "unexpected path outside the repository: " .. line)
    out[#out + 1] = line:sub(#prefix + 1)
  end
  pipe:close()
  if not TARGET_PACKAGE_ROOTS[root] and not OPTIONAL_PACKAGE_ROOTS[root] then
    assert(#out > 0, "package root indexed no Lua files: " .. root)
  end
  return out
end

local function readFile(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local content = handle:read("*a")
  handle:close()
  return content
end

local function pathExists(path)
  local handle = io.open(BASE .. "/" .. path, "r")
  if handle == nil then
    return false
  end
  handle:close()
  return true
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

function T.library_packages_never_import_romdump()
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

function T.romdump_never_imports_runtime_packages()
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

function T.nds_graphics_never_imports_upward()
  local violations = violationsFor(scannedFiles(), function(file, module)
    if file:sub(1, #"libs/nds/src/") ~= "libs/nds/src/" then
      return false
    end
    for _, prefix in ipairs(NDS_FORBIDDEN_LIBS) do
      if module:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end)
  Assert.isTrue(#violations == 0, violationMessage("libs/nds/src imports an upward package:\n", violations))
end

function T.script_platform_never_imports_game_specific_packages()
  local forbidden = { "libs.nds.", "libs.hgss.", "game.", "romdump." }
  local violations = violationsFor(scannedFiles(), function(file, module)
    if file:sub(1, #"libs/script/src/") ~= "libs/script/src/" then
      return false
    end
    for _, prefix in ipairs(forbidden) do
      if module:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end)
  Assert.isTrue(#violations == 0, violationMessage("libs/script/src imports an upward package:\n", violations))
end

function T.nds_love_renderer_has_a_concrete_owner_without_upward_imports()
  local hasRenderer = pathExists("libs/nds/src/love/GxRenderer.lua")
  local files = hasRenderer and luaFilesUnder("libs/nds/src/love") or {}
  local violations = {}
  for _, file in ipairs(files) do
    for _, module in ipairs(requiredModules(readFile(file))) do
      for _, prefix in ipairs(NDS_FORBIDDEN_LIBS) do
        if module:sub(1, #prefix) == prefix then
          violations[#violations + 1] = file .. " requires " .. module
        end
      end
    end
  end
  Assert.isTrue(hasRenderer, "the concrete DS LÖVE renderer must be owned under libs/nds/src/love")
  Assert.isTrue(#violations == 0, violationMessage("the DS LÖVE renderer imports an upward package:\n", violations))
end

function T.nds_sound_does_not_import_project_or_application_packages()
  local violations = violationsFor(scannedFiles(), function(file, module)
    if file:sub(1, #"libs/nds/src/nitro/sound/") ~= "libs/nds/src/nitro/sound/" then
      return false
    end
    for _, prefix in ipairs(NDS_SOUND_FORBIDDEN_LIBS) do
      if module:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end)
  Assert.isTrue(#violations == 0, violationMessage("NDS sound imports an upward package:\n", violations))
end

function T.game_does_not_import_libs_nds_directly()
  local violations = violationsFor(scannedFiles(), function(file, module)
    return file:sub(1, #"game/") == "game/" and module:sub(1, #"libs.nds.") == "libs.nds."
  end)
  Assert.isTrue(#violations == 0, violationMessage("game imports libs.nds directly:\n", violations))
end

function T.hgss_field_owns_world_mechanisms_without_upward_imports()
  local files = luaFilesUnder("libs/hgss/src/field")
  local violations = {}
  for _, file in ipairs(files) do
    for _, module in ipairs(requiredModules(readFile(file))) do
      for _, prefix in ipairs(HGSS_FIELD_FORBIDDEN_LIBS) do
        if module:sub(1, #prefix) == prefix then
          violations[#violations + 1] = file .. " requires " .. module
        end
      end
    end
  end
  Assert.isTrue(#files > 0, "HGSS field runtime must own production world mechanisms")
  Assert.isTrue(#violations == 0, violationMessage("HGSS field runtime imports an invalid package:\n", violations))
end

function T.scanner_configuration_covers_future_library_roots()
  local indexed = {}
  for _, root in ipairs(PACKAGE_ROOTS) do
    indexed[root] = true
  end
  for root in pairs(TARGET_PACKAGE_ROOTS) do
    Assert.isTrue(indexed[root], "architecture scanner omits " .. root)
  end
end

return { tests = T }
