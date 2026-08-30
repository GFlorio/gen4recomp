-- Contract tests for the real-filesystem adapter discovery runs against.
-- `love.filesystem` is rooted at `game/` and answers repo-relative directory
-- listings with an empty table, so an adapter that quietly indexes nothing
-- would report a fully green run over zero suites. Indexing an empty root is
-- therefore a hard error.

local Assert = require("tests.support.Assert")
local RepoFiles = require("tests.runner.RepoFiles")

local T = {}

local function base()
  return love.filesystem.getSourceBaseDirectory()
end

local function has(entries, name)
  for _, entry in ipairs(entries) do
    if entry == name then
      return true
    end
  end
  return false
end

function T.indexes_nested_directories_of_a_root()
  local files = RepoFiles.new(base(), { "libs/engine/tests", "libs/script/tests/core" })

  local top = files.getDirectoryItems("libs/engine/tests")
  Assert.isTrue(has(top, "field_session_test.lua"), "lists an immediate suite")
  Assert.isTrue(has(files.getDirectoryItems("libs/script/tests"), "core"), "lists the promoted script test package")
  Assert.isTrue(has(files.getDirectoryItems("libs/script/tests/core"), "scheduler_test.lua"), "lists a nested suite")
end

function T.reports_file_and_directory_types()
  local files = RepoFiles.new(base(), { "libs/engine/tests", "libs/script/tests/core" })

  Assert.equal(files.getInfo("libs/script/tests/core").type, "directory")
  Assert.equal(files.getInfo("libs/script/tests/core/scheduler_test.lua").type, "file")
  Assert.isNil(files.getInfo("libs/engine/tests/nope"))
  Assert.isNil(files.getInfo("libs/codec/tests"), "a directory outside the indexed roots is unknown")
end

function T.an_empty_root_is_a_hard_error()
  local err = Assert.throws(function()
    RepoFiles.new(base(), { "libs/script/tests/core/does-not-exist" })
  end)
  Assert.isTrue(
    tostring(err):find("indexed no Lua files", 1, true) ~= nil,
    "an empty root fails loudly: " .. tostring(err)
  )
end

-- The root is passed to `find` through a shell, so a path containing an
-- apostrophe must be escaped: an unescaped quote turns the command into
-- garbage and discovery silently indexes nothing (the empty-root assert
-- above would then fire with a misleading cause).
function T.indexes_a_root_whose_path_contains_an_apostrophe()
  local baseDirectory = "/tmp/g4recomp-runner-d31"
  local root = "apostrophe'dir"
  local absoluteRoot = baseDirectory .. "/" .. root
  local function sh(command)
    local pipe = assert(io.popen(command))
    local output = pipe:read("*a")
    pipe:close()
    return output
  end
  sh('rm -rf "' .. absoluteRoot .. '"')
  sh('mkdir -p "' .. absoluteRoot .. '"')
  local path = absoluteRoot .. "/quoted_suite_test.lua"
  local handle = assert(io.open(path, "w"), "cannot write fixture under " .. root)
  handle:write("return { tests = {} }\n")
  handle:close()

  local ok, err = pcall(function()
    local files = RepoFiles.new(baseDirectory, { root })
    Assert.isTrue(
      has(files.getDirectoryItems(root), "quoted_suite_test.lua"),
      "indexes the suite under an apostrophe path"
    )
  end)
  sh('rm -rf "' .. absoluteRoot .. '"')
  if not ok then
    error(err, 2)
  end
end

return { tests = T }
