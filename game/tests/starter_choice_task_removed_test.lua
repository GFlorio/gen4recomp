-- StarterChoiceTask removal regression: the example raw-extension task must
-- not be registered in the production task registry (FieldScripts) or
-- exposed on the raw-script context (ctx.tasks.starterChoice) until a real
-- starter-selection subsystem owns it; it lives under tests/examples. This
-- is a repo-content scan (like undispatched_trigger_kinds_removed_test.lua):
-- it reads source files and never executes the game.

local T = {
  metadata = {
    layer = "component",
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Production trees only, matching the other repo-content scans.
local PRODUCTION_ROOTS = {
  "libs/rom/src",
  "libs/assets/src",
  "libs/engine/src",
  "libs/math/src",
  "game/src",
  "romdump/src",
  "data",
}

-- Every string the production example task could appear under: the module
-- name, the ctx factory, and the registered task type.
local NEEDLES = { "starterChoice", "StarterChoiceTask", "starter_choice" }

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
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

-- No production file may reference the example task in any form.
function T.tests.no_production_code_references_the_example_task()
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
    error("starter_choice task still referenced in production:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

-- The production task module file is gone from the engine source tree.
function T.tests.the_production_task_module_file_is_gone()
  local path = "libs/engine/src/script/tasks/StarterChoiceTask.lua"
  local handle = io.open(path, "r")
  if handle ~= nil then
    handle:close()
  end
  if handle ~= nil then
    error("production task module still exists at " .. path, 0)
  end
end

-- The example task lives at its tests/examples home.
function T.tests.the_example_task_lives_under_tests_examples()
  local path = "tests/examples/StarterChoiceTask.lua"
  local handle = assert(io.open(path, "r"), "example task missing at " .. path)
  handle:close()
end

return T
