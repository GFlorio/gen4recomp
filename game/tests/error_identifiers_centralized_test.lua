-- Centralized error identifiers, protocol strings, and names. Raw error
-- identifiers must be raised through per-subsystem constant tables (the
-- script/errors.lua pattern), never as bare literals at raise sites: a fixed
-- list of codes outside the field engine (storage/cache/import), and a shape
-- scan of the field engine/game-field roots that catches any bare-literal
-- raise/new call regardless of the identifier's name. The shared protocol
-- strings (task types, scheduler states, transition phases, common map-error
-- codes) must be named constants at both producer and consumer; and the
-- misleading names must be renamed. This is a repo-content scan: it reads
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
-- with the owner file(s) at HEAD, for subsystems outside the field engine
-- (storage/cache/import). Field-layer codes are no longer tracked by this
-- positive inventory: `field_engine_and_game_field_have_no_bare_error_literals`
-- below scans the field engine/game-field roots by shape instead, so a new
-- field-layer raw identifier fails automatically without being added here.
local CENTRALIZED_CODES = {
  "IMPORT_BUSY",
  "IMPORT_NOT_NDS",
  "SAVE_PATH_INVALID",
  "SAVE_FILE_MISSING",
  "SAVE_READ_FAILED",
  "SAVE_LUA_PARSE_FAILED",
  "SAVE_LUA_EVAL_FAILED",
  "SAVE_MKDIR_FAILED",
  "SAVE_WRITE_FAILED",
  "SAVE_REMOVE_FAILED",
  "SAVE_REPLACE_FAILED",
  "CACHE_PATH_INVALID",
  "CACHE_FILE_MISSING",
  "CACHE_READ_FAILED",
  "CACHE_LUA_PARSE_FAILED",
  "CACHE_LUA_EVAL_FAILED",
  "CACHE_PUBLISH_ROLLBACK_INCOMPLETE",
  "CACHE_PUBLISH_CLEANUP_FAILED",
  "MAP_CACHE_BAD_TERRAIN",
  "MAP_CACHE_BAD_NEIGHBOR_TERRAIN",
  "MAP_CACHE_READBACK_FAILED",
  "MAP_CACHE_MISSING_ASSET",
  "MAP_CACHE_SCENE_INVALID",
}

-- Field engine/game-field production roots: the field runtime, its renderer,
-- and the game app's field composition. The script subsystem keeps its own
-- catalogue (script/errors.lua) and is excluded here rather than tracked by
-- FieldErrors -- a raw literal inside it is that catalogue's own concern, not
-- this audit's.
local FIELD_ENGINE_ROOTS = {
  "libs/engine/src",
  "game/src/game",
}

local FIELD_ENGINE_EXCLUDED_PREFIXES = {
  "libs/engine/src/script/",
}

local function isExcludedFromFieldAudit(path)
  for _, prefix in ipairs(FIELD_ENGINE_EXCLUDED_PREFIXES) do
    if path:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

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
local function filesUnder(roots)
  local files = {}
  for _, root in ipairs(roots) do
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

local function productionFiles()
  return filesUnder(PRODUCTION_ROOTS)
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

-- Any bare-literal first argument of an `Errors.raise`/`Errors.new` call,
-- anywhere: this is a shape check, not a lookup against a hand-maintained
-- code list, so a brand-new raw identifier fails automatically without the
-- audit needing to learn its name first. `%s` spans the newline of the
-- common multiline call form.
local BARE_RAISE_SITE_PATTERN = 'Errors%.raise%(%s*"[A-Z][A-Z0-9_]*"'
local BARE_NEW_SITE_PATTERN = 'Errors%.new%(%s*"[A-Z][A-Z0-9_]*"'

-- The field engine (libs/engine/src, minus the script subsystem's own
-- catalogue) and the game's field composition (game/src/game) must raise
-- through named `FieldErrors`/`ScriptErrors` constants, never bare literals.
-- Unlike `centralized_error_codes_have_no_raw_raise_sites`, this does not
-- enumerate codes: it rejects the shape of a bare-literal raise/new call, so
-- a future new raw identifier in these roots fails without being added here.
function T.tests.field_engine_and_game_field_have_no_bare_error_literals()
  local files = {}
  for _, path in ipairs(filesUnder(FIELD_ENGINE_ROOTS)) do
    if not isExcludedFromFieldAudit(path) then
      files[#files + 1] = path
    end
  end
  local violations = {}
  for _, site in ipairs(collect(BARE_RAISE_SITE_PATTERN, files)) do
    violations[#violations + 1] = site .. " raises a bare error-code literal"
  end
  for _, site in ipairs(collect(BARE_NEW_SITE_PATTERN, files)) do
    violations[#violations + 1] = site .. " constructs a bare error-code literal"
  end
  if #violations > 0 then
    error(
      "bare error-code literals in the field engine/game-field roots (use a named FieldErrors/ScriptErrors constant):\n  "
        .. table.concat(violations, "\n  "),
      0
    )
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
