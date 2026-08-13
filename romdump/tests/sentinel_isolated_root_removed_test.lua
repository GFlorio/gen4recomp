-- Isolated-root ownership regression: the romdump CLI must never claim to own
-- an isolated import root it does not create or remove. The sentinel root
-- ("script-owned-isolated-root") with its no-op removal existed so the shell's
-- EXIT trap could keep real ownership while the CLI pretended to. Repo-content
-- scan over romdump/src; never executes the CLI.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

local NEEDLES = {
  "script-owned-isolated-root",
}

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

-- Real-filesystem enumeration, UNIX-only by intent like the test runner's
-- own file adapter (tests/runner/RepoFiles.lua).
local function romdumpSourceFiles()
  local files = {}
  local command = "find romdump/src -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list romdump/src: io.popen unavailable")
  for line in pipe:lines() do
    files[#files + 1] = line
  end
  assert(pipe:close(), "cannot list romdump/src")
  table.sort(files)
  return files
end

function T.tests.no_sentinel_isolated_root_remains_in_the_cli()
  local violations = {}
  for _, path in ipairs(romdumpSourceFiles()) do
    local contents = readFile(path)
    for _, needle in ipairs(NEEDLES) do
      if contents:find(needle, 1, true) ~= nil then
        violations[#violations + 1] = path .. " references " .. needle
      end
    end
  end
  if #violations > 0 then
    error("sentinel isolated-root ownership still in romdump:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

return T
