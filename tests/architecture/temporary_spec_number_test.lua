-- Guards against reintroducing temporary planning-spec references in
-- committed source and documentation. The shapes it scans for -- section
-- marks, decision markers, and "the spec" locutions -- name sections and
-- deliverables of a working implementation spec that is not part of the
-- repository (see the project guidance on temporary spec/deliverable/phase
-- identifiers); a comment citing one goes stale the moment the spec is
-- discarded, unlike a comment citing a durable source such as a GBATEK
-- section or a decomp file. Only obvious citation shapes are scanned: the
-- bare identifier "spec" is a legitimate constructor-descriptor name across
-- the script/task APIs (see docs/script-api-v1.md), and "D<number>" is
-- bounded by word boundaries so hex-flavored identifiers (FLAG_UNK_AD0,
-- MAP_D24, _05D9) cannot match. This is a repo-content scan: it reads
-- production, test, and documentation files and never executes the game.

local T = {
  metadata = {
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

-- Every content tree of the repository, including the research documents.
-- The repo-root guidance files (AGENTS.md and friends) are excluded because
-- they state this very rule and legitimately name example identifiers.
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
  "docs",
  "gen4",
}

local SCAN_EXTENSIONS = { "lua", "md" }

-- "spec <number>" style citations.
local SPEC_NUMBER_PATTERN = "spec %d+%.?%d*"
-- "§<number>" style section marks.
local SECTION_MARK_PATTERN = "§ ?%d+%.?%d*"
-- "D<number>" style temporary decision identifiers; word boundaries checked
-- separately because hex-flavored identifiers (FLAG_UNK_AD0, MAP_D24) and
-- offset labels (_05D9) share the D-letter prefix.
local DECISION_ID_PATTERN = "D%d+"
-- Phrase locutions that defer to the discarded spec. The bare word "spec"
-- is deliberately not scanned.
local SPEC_PHRASE_PATTERNS = {
  "per the spec",
  "the spec pins",
  "spec section",
}

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local function scannedFiles()
  local files = {}
  for _, root in ipairs(SCAN_ROOTS) do
    for _, extension in ipairs(SCAN_EXTENSIONS) do
      local command = "find '" .. root .. "' -type f -name '*." .. extension .. "' -print 2>/dev/null"
      local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
      for line in pipe:lines() do
        files[#files + 1] = line
      end
      assert(pipe:close(), "cannot list " .. root)
    end
  end
  table.sort(files)
  return files
end

local function isWordCharacter(character)
  return character:match("%w") ~= nil or character == "_"
end

local function lineOf(contents, position)
  local line = 1
  for i = 1, position do
    if contents:sub(i, i) == "\n" then
      line = line + 1
    end
  end
  return line
end

-- This file defines the scanned shapes and must be able to name them.
local SELF_PATH = "tests/architecture/temporary_spec_number_test.lua"

local function collectMatches(contents, pattern, matches)
  local from = 1
  while true do
    local first, last = contents:find(pattern, from)
    if first == nil then
      break
    end
    matches[#matches + 1] = { first = first, last = last }
    from = last + 1
  end
end

local function appendViolations(path, contents, violations)
  local matches = {}
  collectMatches(contents, SPEC_NUMBER_PATTERN, matches)
  collectMatches(contents, SECTION_MARK_PATTERN, matches)
  for _, phrase in ipairs(SPEC_PHRASE_PATTERNS) do
    collectMatches(contents, phrase, matches)
  end
  collectMatches(contents, DECISION_ID_PATTERN, matches)
  table.sort(matches, function(a, b)
    return a.first < b.first
  end)
  for _, match in ipairs(matches) do
    local previous = contents:sub(match.first - 1, match.first - 1)
    local following = contents:sub(match.last + 1, match.last + 1)
    local bare = contents:sub(match.first, match.last)
    local isDecisionId = bare:match(DECISION_ID_PATTERN) ~= nil
    if not isDecisionId or not (isWordCharacter(previous) or isWordCharacter(following)) then
      -- Hex-flavored identifiers (FLAG_UNK_AD0, MAP_D24) and offset labels
      -- (_05D9) are word-bounded and are not decision markers.
      violations[#violations + 1] = path .. ":" .. lineOf(contents, match.first)
    end
  end
end

function T.tests.no_temporary_spec_number_references_in_source()
  local violations = {}
  for _, path in ipairs(scannedFiles()) do
    if path ~= SELF_PATH then
      appendViolations(path, readFile(path), violations)
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
