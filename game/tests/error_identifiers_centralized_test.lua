-- D37 executable acceptance: error identifiers, protocol strings, and names.
-- The audit's raw error identifiers must be raised through per-subsystem
-- constant tables (the script/errors.lua pattern), never as bare literals at
-- raise sites; the shared protocol strings (task types, scheduler states,
-- transition phases, common map-error codes) must be named constants at both
-- producer and consumer; and the misleading names must be renamed. This is a
-- repo-content scan (like pre_script_fallback_removed_test.lua): it reads
-- production source files and never executes the game.

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Production trees only. Test files keep using the literal codes in
-- throwsCode assertions; the centralized raise sites are a production
-- contract, not a test-file one.
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
}

-- Raw error identifiers the audit names for per-subsystem centralization,
-- with the owner file(s) at HEAD. FieldEventState's whole family is listed,
-- not just the two codes the audit cites, because the per-subsystem table
-- covers the file's raise sites. ACTOR_FACING_INVALID is the D35-added member
-- of the actor family (raised in WarpSystem and FieldObjectActor); the warp
-- resolution codes are the D35-standardized unknown-destination codes
-- (raised in WarpSystem).
local CENTRALIZED_CODES = {
  "EVENT_STATE_TOO_LARGE",
  "EVENT_FLAG_VALUE_INVALID",
  "EVENT_VAR_VALUE_INVALID",
  "EVENT_FLAG_ID_INVALID",
  "EVENT_VAR_ID_INVALID",
  "RENDER_QUEUE_UNKNOWN_ALPHA_CLASS",
  "IMPORT_BUSY",
  "IMPORT_NOT_NDS",
  "CACHE_PATH_INVALID",
  "CACHE_FILE_MISSING",
  "CACHE_LUA_PARSE_FAILED",
  "CACHE_LUA_EVAL_FAILED",
  "CACHE_PUBLISH_ROLLBACK_INCOMPLETE",
  "CACHE_PUBLISH_CLEANUP_FAILED",
  "MAP_CACHE_BAD_TERRAIN",
  "MAP_CACHE_BAD_NEIGHBOR_TERRAIN",
  "MAP_CACHE_READBACK_FAILED",
  "MAP_CACHE_MISSING_ASSET",
  "MAP_CACHE_SCENE_INVALID",
  "ACTOR_OCCUPANCY_CONFLICT",
  "ACTOR_FACING_INVALID",
  "TERRAIN_SURFACE_NOT_FOUND",
  "TERRAIN_SURFACE_AMBIGUOUS",
  "TERRAIN_SURFACE_DISCONNECTED",
  "FIELD_MAP_UNKNOWN",
  "FIELD_DESTINATION_MAP_UNKNOWN",
  "FIELD_DESTINATION_WARP_UNKNOWN",
  "FIELD_DYNAMIC_WARP_UNSUPPORTED",
}

-- Consumer-side raw literals of the shared protocol strings: a named
-- constant must be referenced at both producer and consumer. `= ?` matches
-- both assignment and comparison sites; task-type needles exclude the owner
-- declarations (X.type = "...") by requiring the `taskType`/`register`
-- prefix.
local PROTOCOL_NEEDLES = {
  'taskType%s*==?%s*"movement"',
  'createTask%s*%(%s*"movement"',
  'register%s*%(%s*"actor_pause"',
  'status%s*==?%s*"resume_pending"',
  'status%s*==?%s*"blocked"',
  'phase%s*==?%s*"idle"',
  'phase%s*==?%s*"fade_out"',
  'phase%s*==?%s*"fade_in"',
  'phase%s*==?%s*"load_destination"',
  'phase%s*==?%s*"swap_map"',
  'code%s*==?%s*"FIELD_MAP_UNKNOWN"',
  'code%s*==?%s*"TERRAIN_SURFACE_DISCONNECTED"',
}

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

-- Match a raise-site literal even across the multiline form
-- `Errors.raise(\n  "CODE", ...)`: `%s` spans newlines.
local function raiseSitePattern(code)
  return '%(%s*"' .. code .. '"'
end

local function collect(pattern, files)
  local violations = {}
  for _, path in ipairs(files) do
    local contents = readFile(path)
    local from = 1
    while true do
      local first, last = contents:find(pattern, from)
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
  end
  return violations
end

-- Every centralized code must be referenced through its per-subsystem
-- constant table: no bare literal may appear as the first argument of a
-- raise/new call anywhere in production source.
function T.tests.centralized_error_codes_have_no_raw_raise_sites()
  local files = productionFiles()
  local violations = {}
  for _, code in ipairs(CENTRALIZED_CODES) do
    for _, site in ipairs(collect(raiseSitePattern(code), files)) do
      violations[#violations + 1] = site .. ' raises raw "' .. code .. '"'
    end
  end
  if #violations > 0 then
    error("raw centralized error-code literals at raise sites:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

-- The shared protocol strings must be named constants at both producer and
-- consumer: no raw literal at task-type, scheduler-state, transition-phase,
-- or common map-error comparison/assignment sites.
function T.tests.shared_protocol_strings_use_named_constants()
  local files = productionFiles()
  local violations = {}
  for _, needle in ipairs(PROTOCOL_NEEDLES) do
    for _, site in ipairs(collect(needle, files)) do
      violations[#violations + 1] = site .. " matches " .. needle
    end
  end
  if #violations > 0 then
    error("raw shared-protocol string literals:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

-- The audit's renames: the singular-returning task lookup, the scripted-warp
-- pending field, the importer's start guard, and the direct-warp
-- destinationWarp alias. Presence of the prescribed new names is pinned where
-- the audit prescribes them; `_requireIdle`'s new name is the implementer's
-- choice, so only the misleading name's absence is pinned.
function T.tests.misleading_names_are_renamed()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local contents = readFile(path)
    if contents:find(":tasksById", 1, true) ~= nil then
      violations[#violations + 1] = path .. " still calls Scheduler:tasksById"
    end
  end

  local scheduler = readFile("libs/engine/src/script/Scheduler.lua")
  if scheduler:find("function Scheduler:taskById", 1, true) == nil then
    violations[#violations + 1] = "libs/engine/src/script/Scheduler.lua lacks Scheduler:taskById"
  end

  local mapsService = readFile("libs/engine/src/script/ScriptMapsService.lua")
  if mapsService:find("_pending", 1, true) ~= nil then
    violations[#violations + 1] = "libs/engine/src/script/ScriptMapsService.lua still carries _pending"
  end
  if mapsService:find("pendingWarp", 1, true) == nil then
    violations[#violations + 1] = "libs/engine/src/script/ScriptMapsService.lua lacks pendingWarp"
  end

  local importer = readFile("romdump/src/source/RomImporter.lua")
  if importer:find("_requireIdle", 1, true) ~= nil then
    violations[#violations + 1] = "romdump/src/source/RomImporter.lua still names its start guard _requireIdle"
  end

  local warpSystem = readFile("libs/engine/src/WarpSystem.lua")
  if warpSystem:find("resolutionRecord(sourceMap, warp, destinationMap, warp", 1, true) ~= nil then
    violations[#violations + 1] = "WarpSystem.lua direct branch aliases the trigger record as destinationWarp"
  end

  if #violations > 0 then
    error("misleading names still in production:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

return T
