-- Doc drift test: docs/script-api-v1.md must stay byte-identical to what
-- tools/gen-script-docs renders from Schema.lua. Any schema or constructor
-- index change without `scripts/gen-script-docs.sh` fails here.

local Assert = require("tests.support.Assert")
local DocGen = require("tools.gen-script-docs.DocGen")

local T = {}

function T.checked_in_docs_match_generated_output()
  local root = love.filesystem.getSourceBaseDirectory()
  local path = root .. "/docs/script-api-v1.md"
  local f = assert(io.open(path, "r"), "cannot open docs: " .. path)
  local checkedIn = f:read("*a")
  f:close()
  Assert.equal(DocGen.render(), checkedIn, "docs/script-api-v1.md is stale; run scripts/gen-script-docs.sh")
end

return { tests = T }
