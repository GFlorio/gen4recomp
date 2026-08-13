-- Pre-script fallback removal regression: no production string may reference
-- the deleted pre-script interaction fallback or placeholder dialogue. The
-- adapter module, its fixture manifest (the GOLD player-name fixture), the
-- placeholder message reference and text, the unmapped-interaction text, and
-- the checked-in override files that used the placeholder must all be gone
-- from production code and data after regeneration. This is a repo-content
-- scan: it reads source files and never executes the game.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    layer = "component",
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Production trees only. The fallback's own unit test
-- (libs/engine/tests/pre_script_interaction_adapter_test.lua) and the ROM
-- fixture suite (tests/rom/pre_script_interactions_test.lua) are deleted by
-- the implementation; the scan must not depend on their fate.
local PRODUCTION_ROOTS = {
  "libs/codec/src",
  "libs/assets/src",
  "libs/engine/src",
  "libs/math/src",
  "game/src",
  "romdump/src",
  "data",
}

-- Every string the deletion must have removed. The GOLD fixture is the
-- default player name carried by data/manifests/pre_script_interactions.lua.
local NEEDLES = {
  "msg.project.placeholder",
  "PreScriptInteractionAdapter",
  "pre_script_interactions",
  "UNMAPPED_INTERACTION_TEXT",
  "PLACEHOLDER_TEXT",
  "Nothing is wired here yet.",
  'playerName = "GOLD"',
}

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local function readFileOrNil(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local contents = handle:read("*a")
  handle:close()
  return contents
end

-- Real-filesystem enumeration, UNIX-only by intent like the test runner's
-- own file adapter (tests/runner/RepoFiles.lua).
local function productionFiles()
  local files = {}
  for _, root in ipairs(PRODUCTION_ROOTS) do
    local command = "find '" .. root .. "' -type f -print 2>/dev/null"
    local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
    for line in pipe:lines() do
      files[#files + 1] = line
    end
    assert(pipe:close(), "cannot list " .. root)
  end
  table.sort(files)
  return files
end

-- The fallback adapter module and its fixture manifest (the GOLD fixture)
-- are deleted files, not merely renamed references elsewhere.
function T.tests.the_fallback_module_and_manifest_are_deleted()
  Assert.isNil(readFileOrNil("libs/engine/src/PreScriptInteractionAdapter.lua"))
  Assert.isNil(readFileOrNil("data/manifests/pre_script_interactions.lua"))
end

-- Every production file must be free of the deleted fallback and placeholder
-- strings, including the checked-in overrides after regeneration.
function T.tests.no_production_string_references_remain()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local contents = readFile(path)
    for _, needle in ipairs(NEEDLES) do
      if contents:find(needle, 1, true) ~= nil then
        violations[#violations + 1] = path .. " references " .. needle
      end
    end
  end
  if #violations > 0 then
    error("pre-script fallback strings still in production:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

return T
