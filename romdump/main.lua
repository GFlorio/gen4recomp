-- ROM dump CLI entry point. This app is its own LÖVE root (`love romdump/`);
-- the repo root (the source base directory) is added to package.path first so
-- `require` resolves libs by their full repo-relative path (libs.rom.*,
-- libs.assets.*) independent of the working directory. Cli parses the argv into
-- options; Runner executes the selected headless command and exits with a
-- status code (pumped across frames for the async ROM import).
local ROOT = love.filesystem.getSourceBaseDirectory()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local Cli = require("romdump.src.cli.Cli")
local Runner = require("romdump.src.cli.Runner")

function love.load(argv)
  Runner.load(Cli.parse(argv))
end

function love.update()
  Runner.update()
end
