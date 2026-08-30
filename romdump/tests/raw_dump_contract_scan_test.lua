-- Raw-dump contract scan: the raw-dump identity literals (the generated
-- metadata/index paths, the completion marker) have exactly one owner -- the
-- RawDumpContract module -- and the importer state strings are one named
-- vocabulary (RomImporter.STATES) that the UI/runner consumers reference
-- instead of raw strings. Repo-content scan like
-- error_identifiers_centralized_test.lua: reads production source files and
-- never executes the game.

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Production trees only. Test files keep using the literal paths and states
-- in fixtures; the single-owner contract is a production contract, not a
-- test-file one.
local PRODUCTION_ROOTS = {
  "libs/codec/src",
  "libs/assets/src",
  "libs/hgss/src",
  "libs/errors/src",
  "libs/math/src",
  "libs/storage/src",
  "game/src",
  "romdump/src",
  "data",
}

-- The raw-dump identity literals that producers (RomExtractor) and consumers
-- (RomImporter.isReady, RomFs, CacheBuilder) must agree on. They are allowed
-- in exactly one production file: the contract module itself.
local CONTRACT_PATH = "romdump/src/source/RawDumpContract.lua"
local RAW_DUMP_LITERALS = {
  "data/generated/rom_metadata.lua",
  "data/generated/romfs_index.lua",
  "data/generated/overlay_index.lua",
  "rom-dump.complete",
}

-- The importer state strings are one named vocabulary. These consumer files
-- must compare/assign only named states. The scan is scoped to them because
-- the same words legitimately describe other state machines elsewhere
-- (menu status, scheduler phases).
local IMPORTER_STATE_CONSUMERS = {
  "romdump/src/source/RomImporter.lua",
  "romdump/src/cli/Runner.lua",
  "game/src/game/App.lua",
  "game/src/launcher/ImportState.lua",
}

-- `state = "x"`, `state == "x"`, and `state ~= "x"` at importer consumer
-- sites must name the state constant instead. `_setState` is the pointless
-- one-line setter the importer must not keep.
local IMPORTER_STATE_NEEDLES = {
  'state%s*[~=]?=?%s*"idle"',
  'state%s*[~=]?=?%s*"reading"',
  'state%s*[~=]?=?%s*"verifying"',
  'state%s*[~=]?=?%s*"extracting"',
  'state%s*[~=]?=?%s*"complete"',
  'state%s*[~=]?=?%s*"error"',
}
local IMPORTER_PLAIN_NEEDLES = { "_setState" }

-- The ambiguous map-selector parameter name must be a domain name in the
-- app file this cleanup touches.
local AMBIGUOUS_NAME_FILES = {
  "game/src/game/App.lua",
}
local AMBIGUOUS_NAME_NEEDLES = { "idOrSymbol" }

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

-- Match a needle across a file, returning "path:line" sites. A nil pattern
-- means a plain substring match.
local function collect(needle, files, plain)
  local sites = {}
  for _, path in ipairs(files) do
    local contents = readFile(path)
    local from = 1
    while true do
      local first, last = contents:find(needle, from, plain and true or nil)
      if first == nil then
        break
      end
      local line = 1
      for i = 1, first do
        if contents:sub(i, i) == "\n" then
          line = line + 1
        end
      end
      sites[#sites + 1] = path .. ":" .. line
      from = last + 1
    end
  end
  return sites
end

-- The contract module exists, owns every raw-dump identity literal, and no
-- other production file duplicates one.
function T.tests.raw_dump_identity_literals_live_only_in_the_contract()
  local files = productionFiles()
  local violations = {}
  local ok, contract = pcall(readFile, CONTRACT_PATH)
  if not ok then
    violations[#violations + 1] = CONTRACT_PATH .. " does not exist; it must own every raw-dump identity literal"
  else
    for _, literal in ipairs(RAW_DUMP_LITERALS) do
      if contract:find(literal, 1, true) == nil then
        violations[#violations + 1] = CONTRACT_PATH .. " must own the raw-dump literal " .. literal
      end
    end
  end
  local outside = {}
  for _, path in ipairs(files) do
    if path ~= CONTRACT_PATH then
      outside[#outside + 1] = path
    end
  end
  for _, literal in ipairs(RAW_DUMP_LITERALS) do
    for _, site in ipairs(collect(literal, outside, true)) do
      violations[#violations + 1] = site .. " duplicates raw-dump literal " .. literal
    end
  end
  if #violations > 0 then
    error(
      "raw-dump identity literals must live only in " .. CONTRACT_PATH .. ":\n  " .. table.concat(violations, "\n  "),
      0
    )
  end
end

-- Importer consumers compare/assign named states, never raw state strings,
-- and the pointless one-line state setter is gone.
function T.tests.importer_state_strings_use_named_vocabulary()
  local violations = {}
  for _, needle in ipairs(IMPORTER_STATE_NEEDLES) do
    for _, site in ipairs(collect(needle, IMPORTER_STATE_CONSUMERS)) do
      violations[#violations + 1] = site .. " uses a raw importer state"
    end
  end
  for _, needle in ipairs(IMPORTER_PLAIN_NEEDLES) do
    for _, site in ipairs(collect(needle, IMPORTER_STATE_CONSUMERS, true)) do
      violations[#violations + 1] = site .. " keeps " .. needle
    end
  end
  if #violations > 0 then
    error("importer consumers must use the named state vocabulary:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

-- The touched app file names the map selector by its domain type.
function T.tests.ambiguous_map_selector_names_are_renamed()
  local violations = {}
  for _, needle in ipairs(AMBIGUOUS_NAME_NEEDLES) do
    for _, site in ipairs(collect(needle, AMBIGUOUS_NAME_FILES, true)) do
      violations[#violations + 1] = site .. " still uses " .. needle
    end
  end
  if #violations > 0 then
    error("map selectors must be named by domain type:\n  " .. table.concat(violations, "\n  "), 0)
  end
end

return T
