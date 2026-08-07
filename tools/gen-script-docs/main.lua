-- Headless doc generator app (`love tools/gen-script-docs/`). Regenerates
-- docs/script-api-v1.md from the schema and exits. Output is deterministic:
-- re-running against an unchanged schema produces a byte-identical file.

local APP_DIR = love.filesystem.getSource()
local REPO_ROOT = APP_DIR .. "/../.."
package.path = REPO_ROOT .. "/?.lua;" .. REPO_ROOT .. "/?/init.lua;" .. package.path

local DocGen = require("tools.gen-script-docs.DocGen")

local DEFAULT_OUT = REPO_ROOT .. "/docs/script-api-v1.md"

function love.load(argv)
  local outPath = argv and argv[1] or DEFAULT_OUT
  local f = assert(io.open(outPath, "w"), "cannot open output: " .. outPath)
  f:write(DocGen.render())
  f:close()
  love.event.quit(0)
end
