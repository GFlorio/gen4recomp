-- Temporary/specification language regression: durable production files may
-- not describe themselves as provisional, under development, workstream N,
-- or temporary in the planning sense. This is a repo-content scan: it reads
-- source files and never executes the game.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    layer = "component",
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Production trees only, including the root-level mod-facing gen4/ DSL.
local PRODUCTION_ROOTS = {
  "libs/codec/src",
  "libs/assets/src",
  "libs/engine/src",
  "libs/errors/src",
  "libs/math/src",
  "libs/storage/src",
  "game/src",
  "romdump/src",
  "data",
  "gen4",
}

-- Planning/specification language the audit flagged in durable files. The
-- "temporary" needle stays narrow (lowercase standalone token): atomic-replace
-- staging siblings and script-scope temporary locals describe real mechanisms,
-- not planning language, and stay legal.
local NEEDLES = {
  { pattern = "provisional", caseInsensitive = true },
  { pattern = "under development", caseInsensitive = true },
  { pattern = "may change in a future API", caseInsensitive = true },
  { pattern = "WS%d+", caseInsensitive = false },
  { pattern = "temporary%f[^%w_]", caseInsensitive = false },
}

local DURABLE_TEMPORARY_PHRASES = { "temporary sibling", "temporary locals" }

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

local function isDurableTemporary(line)
  local lowered = line:lower()
  for _, phrase in ipairs(DURABLE_TEMPORARY_PHRASES) do
    if lowered:find(phrase, 1, true) ~= nil then
      return true
    end
  end
  return false
end

-- Every production file must be free of planning/specification language,
-- reporting each surviving line so the cleanup knows exactly what to replace.
function T.tests.no_temporary_spec_language_remains_in_production()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local lineNumber = 0
    -- Append a newline so the final line is captured; "(.-)\n" yields each
    -- physical line exactly once (blank lines included, no empty artifacts).
    for line in (readFile(path) .. "\n"):gmatch("(.-)\n") do
      lineNumber = lineNumber + 1
      for _, needle in ipairs(NEEDLES) do
        local hay = line
        local pat = needle.pattern
        if needle.caseInsensitive then
          hay = line:lower()
          pat = pat:lower()
        end
        if hay:find(pat) ~= nil and not isDurableTemporary(line) then
          violations[#violations + 1] = string.format("%s:%d: %s", path, lineNumber, line)
          break
        end
      end
    end
  end
  if #violations > 0 then
    error("temporary/specification language still in production:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

return T
