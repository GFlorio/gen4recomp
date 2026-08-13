-- Cell-protection removal regression: coverage protection claimed individual
-- cell keys (protectCells/updateCoverage) while eviction is map-granular and
-- the protection check only tested nonemptiness, so it was a second map pin
-- coexisting with transition-owned map pinning. The cell mechanism must not
-- exist in production code; transition-owned pinning (protectMap) is the one
-- protection surface. This is a repo-content scan (like
-- pre_script_fallback_removed_test.lua): it reads source files and never
-- executes the game.

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Production trees only, matching the other repo-content regression scans.
local PRODUCTION_ROOTS = {
  "libs/codec/src",
  "libs/assets/src",
  "libs/engine/src",
  "libs/math/src",
  "game/src",
  "romdump/src",
  "data",
}

-- The cell-protection surface. The strings are unique to the deleted
-- mechanism (FieldMapLoader's protectCells/protectedCells, removed with the
-- cell-protection surface; protectMap and protectedMaps stay).
local CELL_PROTECTION_NEEDLES = { "protectCells", "protectedCells" }

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

-- No production file may name the cell-protection surface.
function T.tests.no_production_code_references_cell_protection()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local contents = readFile(path)
    for _, needle in ipairs(CELL_PROTECTION_NEEDLES) do
      if contents:find(needle, 1, true) ~= nil then
        violations[#violations + 1] = path .. " references " .. needle
      end
    end
  end
  if #violations > 0 then
    error("cell protection still in production:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

return T
