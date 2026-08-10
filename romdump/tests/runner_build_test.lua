-- CLI build-cache outcome when no ready dump is available. Cache construction
-- itself belongs to CachePipeline and its writer tests; Runner owns command
-- selection and the process exit status.

local Assert = require("tests.support.Assert")
local RomImporter = require("libs.rom.src.RomImporter")
local Runner = require("romdump.src.cli.Runner")

local T = {}

function T.build_cache_without_a_ready_dump_exits_with_usage_failure()
  local realIsReady, realQuit = RomImporter.isReady, love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local exitCode
  RomImporter.isReady = function()
    return false
  end
  love.event.quit = function(code)
    exitCode = code
  end

  local ok, err = xpcall(function()
    Runner.load({ buildCache = true })
  end, debug.traceback)
  RomImporter.isReady, love.event.quit = realIsReady, realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 2)
end

return T
