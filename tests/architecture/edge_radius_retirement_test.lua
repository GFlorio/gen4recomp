-- Static architecture guard: edge marking is exactly one semantic pixel wide
-- (see libs/engine/src/shaders/edge.glsl's dsTexel derivation), never a
-- radius that scales with host/color resolution. This locks the boundary
-- against reintroducing a host-resolution-dependent edge width -- the exact
-- shortcut the render pipeline architecture prohibits -- by scanning for the
-- three symbols that implemented it (a configurable radius uniform, its Lua
-- sender, and the DS-native-height-to-pixel derivation) across the live
-- source tree. This is a repo-content scan: it reads source files and never
-- executes the game.

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Every discovery root in tests/run.lua, plus the production trees they sit
-- beside, plus the shader sources (not Lua, but where the retired uniform
-- and its GLSL constant lived).
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

local RETIRED_SYMBOLS = {
  "u_edgeRadius",
  "fieldEdgeRadiusPixels",
  "MAX_EDGE_RADIUS",
}

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

-- This guard's own source necessarily names the retired symbols; excluded the
-- same way lint.sh excludes itself from its own temporary-reference scan.
local SELF_PATH = "tests/architecture/edge_radius_retirement_test.lua"

local function sourceFiles()
  local files = {}
  for _, root in ipairs(SCAN_ROOTS) do
    local command = "find '" .. root .. "' -type f \\( -name '*.lua' -o -name '*.glsl' \\) -print 2>/dev/null"
    local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
    for line in pipe:lines() do
      if line ~= SELF_PATH then
        files[#files + 1] = line
      end
    end
    assert(pipe:close(), "cannot list " .. root)
  end
  table.sort(files)
  return files
end

function T.tests.no_retired_edge_radius_symbol_appears_anywhere_live()
  local violations = {}
  for _, path in ipairs(sourceFiles()) do
    local contents = readFile(path)
    for _, symbol in ipairs(RETIRED_SYMBOLS) do
      if contents:find(symbol, 1, true) then
        violations[#violations + 1] = path .. ": " .. symbol
      end
    end
  end
  if #violations > 0 then
    error("retired host-resolution-dependent edge radius symbols found:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

return T
