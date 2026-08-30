-- Guards against reintroducing temporary planning-spec references of the
-- form "spec" followed by a section number in permanent comments/docstrings.
-- Those numbers name
-- sections of a working implementation spec that is not part of the
-- repository (see the project guidance on temporary spec/deliverable
-- identifiers); a comment citing one goes stale the moment the spec is
-- discarded, unlike a comment citing a durable source such as a GBATEK
-- section or a decomp file. This is a repo-content scan: it reads
-- production and test source files and never executes the game.

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Every discovery root in tests/run.lua, plus the production trees they sit
-- beside. Test-only roots are included because 16.4's violation lived in
-- test comments, not production source.
local SCAN_ROOTS = {
  "libs/codec",
  "libs/errors",
  "libs/storage",
  "libs/math",
  "libs/assets",
  "libs/engine",
  "game",
  "romdump",
  "data",
  "tests",
}

local SPEC_NUMBER_PATTERN = "spec %d+%.%d+"
local GENERATED_LABEL_PATTERN = "generated [A-Z]%d%d"

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local function luaFiles()
  local files = {}
  for _, root in ipairs(SCAN_ROOTS) do
    local command = "find '" .. root .. "' -type f -name '*.lua' -print 2>/dev/null"
    local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
    for line in pipe:lines() do
      files[#files + 1] = line
    end
    assert(pipe:close(), "cannot list " .. root)
  end
  table.sort(files)
  return files
end

function T.tests.no_temporary_spec_number_references_in_source()
  local violations = {}
  for _, path in ipairs(luaFiles()) do
    local contents = readFile(path)
    local from = 1
    while true do
      local first, last = contents:find(SPEC_NUMBER_PATTERN, from)
      if first == nil then
        break
      end
      local line = 1
      for i = 1, first do
        if contents:sub(i, i) == "\n" then
          line = line + 1
        end
      end
      violations[#violations + 1] = path .. ":" .. line
      from = last + 1
    end
    if contents:find(GENERATED_LABEL_PATTERN) then
      violations[#violations + 1] = path .. ": temporary generated label"
    end
  end
  if #violations > 0 then
    error(
      "temporary planning-spec references found (cite the actual behavior or a durable source instead):\n  "
        .. table.concat(violations, "\n  "),
      0
    )
  end
end

return T
