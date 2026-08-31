-- Repository-level generated script documentation parity check.

local Assert = require("tests.support.Assert")
local DocGen = require("tools.gen-script-docs.DocGen")

local T = {
  metadata = {
    tags = { "architecture", "repository-tooling" },
  },
  tests = {},
}

local BASE = love.filesystem.getSourceBaseDirectory()

local function readFile(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

function T.tests.script_docs_match_the_final_schema_source()
  local generated = DocGen.render()
  local checkedIn = readFile("docs/script-api-v1.md")
  Assert.equal(checkedIn, generated, "script API documentation must be generated from libs/script")
end

return T
