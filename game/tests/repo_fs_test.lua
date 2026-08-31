-- RepoFs path confinement: the repo-relative path guard must reject every
-- traversal form (leading/embedded `..`, dot components, backslash and mixed
-- separators, and canonical-root escapes) loudly at the boundary, while normal
-- relative paths keep resolving. This is the sole confinement defense for
-- manifest-supplied file ids, so rejection must be an error, never a silent
-- nil that is indistinguishable from a missing file. Tests run with the repo
-- root as cwd and read real checked-in files, like script_override_test.lua.

local Assert = require("tests.support.Assert")

local RepoFs = require("game.src.RepoFs")

local T = {
  metadata = {
    tags = { "security", "regression" },
  },
  tests = {},
}

local function assertRejected(fs, path)
  Assert.throws(function()
    fs:read(path)
  end, "traversal path must be rejected: " .. path)
end

function T.tests.traversal_paths_are_rejected()
  local fs = RepoFs.new("data")
  for _, path in ipairs({
    "scripts/../../../../outside",
    "../outside",
    "data/../outside",
    "scripts/../../scripts/../../../../outside",
    "scripts/../outside",
    "./manifests/example.lua",
    "..\\outside",
    "scripts\\..\\outside",
    "scripts/..\\outside",
  }) do
    assertRejected(fs, path)
  end
end

function T.tests.normal_relative_paths_still_resolve()
  local fs = RepoFs.new("game")
  local content = fs:read("src/RepoFs.lua")
  Assert.notNil(content, "normal path must resolve")
  Assert.notNil(string.find(content --[[@as string]], "RepoFs"), "resolved content must be the real file")

  local fsWithTrailingSlash = RepoFs.new("app/")
  Assert.notNil(fsWithTrailingSlash:read("main.lua"), "trailing-slash root must still resolve")

  Assert.isNil(fs:read("no/such/file.lua"), "a missing normal path stays a silent nil")
end

function T.tests.canonical_root_escape_attempts_fail_at_the_boundary()
  local fs = RepoFs.new("game")
  assertRejected(fs, "src/../../AGENTS.md")
  assertRejected(fs, "src/game/../../../../README.md")
end

return T
