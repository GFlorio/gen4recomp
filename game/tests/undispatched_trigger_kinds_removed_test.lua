-- Undispatched trigger-kind removal regression: the bindings platform binds
-- only trigger kinds a dispatcher resolves (object and background). The
-- coordinate/map_init/map_enter/map_resume kinds must not exist in
-- production code or in the checked-in vanilla manifest, and the Elm's Lab
-- aide binding (map:61:object:2) must survive the manifest cleanup. The
-- manifest is loaded directly (pure data); the code needles are unique to
-- the deleted kinds. This is a repo-content scan (like
-- pre_script_fallback_removed_test.lua): it reads source files and never
-- executes the game.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Production trees only, matching the D11 scan.
local PRODUCTION_ROOTS = {
  "libs/codec/src",
  "libs/assets/src",
  "libs/engine/src",
  "libs/math/src",
  "game/src",
  "romdump/src",
  "data",
}

-- The map-lifecycle trigger kinds no dispatcher resolves. The strings are
-- unique to the deleted kinds (Bindings.lua today, gone after D12).
local UNDISPATCHED_KINDS = { "map_init", "map_enter", "map_resume" }

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

-- No production file may name a trigger kind no dispatcher resolves.
function T.tests.no_production_code_references_undispatched_trigger_kinds()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local contents = readFile(path)
    for _, kind in ipairs(UNDISPATCHED_KINDS) do
      if contents:find(kind, 1, true) ~= nil then
        violations[#violations + 1] = path .. " references " .. kind
      end
    end
  end
  if #violations > 0 then
    error("undispatched trigger kinds still in production:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

-- The checked-in vanilla manifest binds only dispatched kinds: no map may
-- carry a coordinate or map-lifecycle section, including empty ones.
function T.tests.the_vanilla_manifest_carries_no_undispatched_binding_kinds()
  local manifest = require("data.scripts.manifests.vanilla_bindings")
  local violations = {}
  for mapId, map in pairs(manifest.maps) do
    for _, kind in ipairs({ "coordinates", "map_init", "map_enter", "map_resume" }) do
      if map[kind] ~= nil then
        violations[#violations + 1] = string.format("map %d carries a %s section", mapId, kind)
      end
    end
  end
  if #violations > 0 then
    error("vanilla bindings manifest still carries undispatched kinds:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

-- The Elm's Lab aide binding (map 61 object 2) is bound to its stable
-- script id and must survive the coordinate cleanup.
function T.tests.the_elms_lab_aide_binding_survives()
  local manifest = require("data.scripts.manifests.vanilla_bindings")
  Assert.equal(manifest.maps[61].objects["map:61:object:2"], "vanilla.hgss.scr_seq.0843.script_002")
end

return T
